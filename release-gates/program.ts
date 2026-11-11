// The Release Gates trick: the release gate. Seven gates, each read on this machine. When all seven are green it asks
// one Decision, "Tag v<version>?". The trick never tags: a yes is a dated record in its state folder, and the
// person's answer reaches the release session through replyTo. That session tags and pushes.
//   1 CI on the branch   gh run list (read only, cached 60 s); a red run adds its failed jobs
//   2 Browser leg        the newest table.md under leg_results
//   3 Core legs          the newest leg-core-*.txt under leg_logs
//   4 Windows rehearsal  minor = false skips it; else the rehearsal file ends "rollback: ok"
//   5 Changelog          CHANGELOG.md on the branch: nothing under Unreleased, the version on top, not tagged
//   6 No peer release    the hold file is absent
//   7 Counsel done       the counsel note names the version and is newer than the newest tag
// A gate that cannot be read is idle, "no report", never red and never green. TRICK_FIXTURE=all-green forces
// every gate green, for the tests only. Asked again: a yes ends the key for that version; not-yet and a
// dismiss close it for 24 h. The records, the cache, the tool lookup and `show` are Collie's helper, trick.ts (v4).
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join } from "node:path";

import { DAY_MS, MINUTE_MS, age, clip, iso, mapText, mask, minute, now as clock, run, v, type Node, type Tone } from "./trick.ts";

type GateState = "done" | "working" | "waiting" | "idle";
interface Gate { id: string; name: string; state: GateState; detail: string; proof?: string; tail?: string[] }
interface Ci { state: GateState; detail: string; proof: string; url: string; tail: string[] }
const RUNNING_MS = 40 * MINUTE_MS;
const NO_REPORT = "no report";
const STATE_WORD: Record<GateState, string> = { done: "green", working: "running", waiting: "red", idle: "not yet" };
const STATE_TONE: Record<GateState, Tone> = { done: "ok", working: "accent", waiting: "danger", idle: "muted" };
const str = (value: unknown, fallback = ""): string => (typeof value === "string" ? value : fallback);
const day = (ms: number): string => iso(ms).slice(0, 10);
/** No em dash on screen, a comma instead, and never a longer string: "a—b" is "a,b", "a — b" is "a, b". */
const noDash = (text: string): string => text.replace(/\s*—\s*/g, (m) => (m.length > 1 ? ", " : ","));

run(async (t) => {
  // Every string the phone gets is masked (keys, the home folder) and carries no em dash.
  t.onPrint((doc) => mapText(doc, (s) => noDash(mask(s))));
  const now = clock();
  const repo = str(t.config.repo);
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) throw new Error("config.toml: repo must be owner/name");
  const version = str(t.config.version).replace(/^v/, "");
  const releaseSession = str(t.config.release_session, "release");
  const workflow = str(t.config.workflow, "ci.yml");
  const show = t.show(["tabbar"]);
  if (t.config.mark !== undefined) t.configWarn('mark is gone: write show = ["tabbar"] instead');
  t.fresh("15m");

  // No release open: one muted row, no count anywhere, no Decision.
  if (version === "") {
    t.asOf(now);
    t.session({ subtitle: "no release open", view: [v.list([v.row("no release open", { tone: "muted" })])] });
    return;
  }
  if (!/^\d+\.\d+\.\d+(?:-[a-z]+\.\d+)?$/.test(version)) throw new Error("config.toml: version must look like 2.4.0 or 2.4.0-rc.1");
  const base = version.replace(/-.*$/, "");
  const branch = str(t.config.branch, "main");
  const minor = t.config.minor === true;
  const p = (key: string): string => t.path(str(t.config[key]));
  const cfg = { checkout: p("checkout"), legResults: p("leg_results"), legLogs: p("leg_logs"), rehearsal: p("rehearsal"), hold: p("hold"), counsel: p("counsel") };
  const fixture = process.env.TRICK_FIXTURE ?? "";
  const gh = t.tool("gh");
  const git = t.tool("git");
  const yesLog = t.log<{ rid: string; at: string; version: string; answer: string; fixture: string | null; seen: string | null }>("tag-yes");
  const dismissed = t.log("tag-dismissed");
  /** The read verbs this trick may run. Anything else throws before it runs: the trick never tags or pushes. */
  const read = async (tool: string, verb: string, args: string[]) => {
    if (!["gh run list", "gh run view", "git for-each-ref", "git show"].includes(verb)) throw new Error(verb + " is not a read verb");
    const r = await t.sh(tool, args, { timeoutMs: 6000 });
    return { ok: r.ok, out: r.stdout, err: r.stderr };
  };

  // ── The newest tag of the checkout ──
  let tags = new Set<string>();
  let newestTag: { name: string; at: number } | null = null;
  if (git !== null && cfg.checkout !== "" && existsSync(cfg.checkout)) {
    const r = await read(git, "git for-each-ref", ["-C", cfg.checkout, "for-each-ref", "--sort=-creatordate", "--format=%(refname:short) %(creatordate:unix)", "refs/tags"]);
    const lines = r.ok ? r.out.trim().split("\n").filter((l) => l !== "") : [];
    tags = new Set(lines.map((l) => l.split(" ")[0] ?? ""));
    const first = lines[0]?.split(" ");
    if (first !== undefined && first.length >= 2) newestTag = { name: first[0] ?? "", at: Number(first[1]) * 1000 };
  }
  /** A report from before the newest tag is not a report for this release: idle, never green. */
  const older = (g: Gate, at: number, what: string): Gate | null => (newestTag === null || at > newestTag.at ? null : { ...g, state: "idle", detail: NO_REPORT + " since " + newestTag.name + ": " + what + " is older" });

  async function gateCi(): Promise<{ gate: Gate; at: number; url: string }> {
    const g: Gate = { id: "ci", name: "CI on " + branch, state: "idle", detail: NO_REPORT };
    if (gh === null) return { gate: { ...g, detail: NO_REPORT + ": gh not found" }, at: now, url: "" };
    // Cached 60 s; a tap takes the kept copy at any age, so it never waits on the network.
    const got = await t.cached<Ci>("cache-ci", t.tap !== null ? Infinity : MINUTE_MS, async (): Promise<Ci> => {
      const r = await read(gh, "gh run list", ["run", "list", "-R", repo, "--branch", branch, "--workflow", workflow, "--limit", "1", "--json", "databaseId,status,conclusion,headSha,createdAt,url"]);
      if (!r.ok) throw new Error("gh failed: " + clip((r.err.trim().split("\n")[0] ?? "") || "no reason", 160));
      const runOf = (JSON.parse(r.out) as Record<string, string | number>[])[0];
      if (runOf === undefined) return { state: "idle", detail: NO_REPORT + ": no CI run on " + branch, proof: "", url: "", tail: [] };
      const sha = String(runOf.headSha).slice(0, 9);
      const s: GateState = runOf.status !== "completed" ? "working" : runOf.conclusion === "success" ? "done" : "waiting";
      let tail: string[] = [];
      if (s === "waiting") {
        const view = await read(gh, "gh run view", ["run", "view", String(runOf.databaseId), "-R", repo, "--json", "jobs"]);
        const jobs = view.ok ? (JSON.parse(view.out) as { jobs: { name: string; conclusion: string; steps?: { name: string; conclusion: string }[] }[] }).jobs : [];
        tail = jobs.filter((j) => j.conclusion !== "success" && j.conclusion !== "skipped").flatMap((j) => ["job " + j.name + ": " + j.conclusion, ...(j.steps ?? []).filter((x) => x.conclusion === "failure").map((x) => "  step " + x.name + ": failure")]);
      }
      const word = s === "working" ? "runs now" : String(runOf.conclusion);
      return { state: s, detail: sha + ", " + word + ", " + day(Date.parse(String(runOf.createdAt))), proof: sha + " " + word, url: String(runOf.url ?? ""), tail };
    });
    if (got.value === null) return { gate: { ...g, detail: NO_REPORT + ": " + (got.error ?? "") }, at: got.at, url: "" };
    const problem = got.error === null ? null : got.error + ", showing the read of " + age(now - got.at) + " ago";
    const detail = problem === null ? got.value.detail : got.value.detail + " (" + problem + ")";
    return { gate: { ...g, state: got.value.state, detail, proof: got.value.proof, tail: got.value.tail }, at: got.at, url: got.value.url ?? "" };
  }

  function gateLeg(): Gate {
    const g: Gate = { id: "leg", name: "Browser leg", state: "idle", detail: NO_REPORT };
    if (cfg.legResults === "" || !existsSync(cfg.legResults)) return g;
    const runs = readdirSync(cfg.legResults).filter((d) => /^\d{4}-\d{2}-\d{2}T/.test(d)).sort().reverse();
    const newest = runs[0];
    if (newest === undefined) return g;
    if (!existsSync(join(cfg.legResults, newest, "table.md")) && now - statSync(join(cfg.legResults, newest)).mtimeMs < RUNNING_MS) return { ...g, state: "working", detail: "run " + newest.slice(0, 16) + " has no table yet" };
    const runDir = runs.find((d) => existsSync(join(cfg.legResults, d, "table.md")));
    if (runDir === undefined) return g;
    const stale = older(g, Date.parse(runDir.replace(/T(\d\d)-(\d\d)-(\d\d)/, "T$1:$2:$3")), "run " + runDir.slice(0, 16));
    if (stale !== null) return stale;
    const rows = readFileSync(join(cfg.legResults, runDir, "table.md"), "utf8").split("\n").filter((l) => /^\|\s*[a-z]+\s*\|/.test(l) && !/^\|\s*harness\s*\|/.test(l)).map((l) => l.split("|").map((c) => c.trim()));
    const red = rows.filter((c) => c[3] !== "pass");
    let mode = "";
    try {
      const tiers = Object.values((JSON.parse(readFileSync(join(cfg.legResults, runDir, "model.json"), "utf8")) as { tiers?: Record<string, { tier?: string }> }).tiers ?? {});
      mode = tiers.length > 0 && tiers.every((x) => x.tier === "replay") ? ", replay" : ", live";
    } catch {
      mode = "";
    }
    const score = rows.length - red.length + "/" + rows.length;
    const out: Gate = { ...g, state: rows.length > 0 && red.length === 0 ? "done" : "waiting", detail: score + mode + ", " + runDir.slice(0, 10), proof: score + mode.replace(",", "") };
    if (red.length > 0) out.tail = red.map((c) => c[1] + " " + c[2] + ": " + c[3] + ": " + (c[5] ?? ""));
    return out;
  }

  function gateCore(): Gate {
    const g: Gate = { id: "core", name: "Core legs", state: "idle", detail: NO_REPORT };
    if (cfg.legLogs === "" || !existsSync(cfg.legLogs)) return g;
    const newest = readdirSync(cfg.legLogs).filter((f) => /^leg-core-.*\.txt$/.test(f)).map((f) => ({ f, at: statSync(join(cfg.legLogs, f)).mtimeMs })).sort((a, b) => b.at - a.at)[0];
    if (newest === undefined) return g;
    const stale = older(g, newest.at, newest.f);
    if (stale !== null) return stale;
    const text = readFileSync(join(cfg.legLogs, newest.f), "utf8");
    let passed = 0;
    let failed = 0;
    for (const m of text.matchAll(/^\s+(\d+) (passed|failed)/gm)) if (m[2] === "passed") passed += Number(m[1]); else failed += Number(m[1]);
    if (passed + failed === 0) return now - newest.at < RUNNING_MS ? { ...g, state: "working", detail: newest.f + " runs now" } : { ...g, state: "waiting", detail: newest.f + " stopped without a result" };
    const score = passed + "/" + (passed + failed);
    const out: Gate = { ...g, state: failed === 0 ? "done" : "waiting", detail: score + ", " + basename(newest.f, ".txt").replace(/^leg-core-/, "") + ", " + day(newest.at), proof: score };
    // One red case often fails the cases after it: the first red line is the one to read.
    if (failed > 0) out.tail = text.split("\n").filter((l) => /^\s+(✘|×)\s+\d+/.test(l) || /^\s+Error: /.test(l)).map((l) => l.trim());
    return out;
  }

  function gateWindows(): Gate {
    const g: Gate = { id: "windows", name: "Windows rehearsal", state: "idle", detail: NO_REPORT };
    if (!minor) return { ...g, state: "done", detail: "not a minor: the rehearsal is skipped", proof: "skipped, not a minor" };
    if (cfg.rehearsal === "" || !existsSync(cfg.rehearsal)) return g;
    const lines = readFileSync(cfg.rehearsal, "utf8").trim().split("\n");
    const last = (lines[lines.length - 1] ?? "").trim();
    const at = statSync(cfg.rehearsal).mtimeMs;
    const stale = older(g, at, "the rehearsal file");
    if (stale !== null) return stale;
    if (last === "rollback: ok") return { ...g, state: "done", detail: "rollback: ok, " + day(at), proof: "rollback: ok" };
    return { ...g, state: "waiting", detail: "last line: " + clip(last, 80), tail: lines.slice(-8) };
  }

  async function gateChangelog(): Promise<Gate> {
    const g: Gate = { id: "changelog", name: "Changelog", state: "idle", detail: NO_REPORT };
    if (git === null || cfg.checkout === "" || !existsSync(cfg.checkout)) return g;
    const r = await read(git, "git show", ["-C", cfg.checkout, "show", branch + ":CHANGELOG.md"]);
    if (!r.ok) return { ...g, detail: NO_REPORT + ": no CHANGELOG.md on " + branch };
    const bulletsOf = (section: string): string[] => section.split("\n").filter((l) => /^- \S/.test(l));
    const anchor = r.out.indexOf("\n## [Unreleased]\n");
    let rest = r.out;
    let unreleased: string[] = [];
    if (anchor >= 0) {
      const after = r.out.slice(anchor + "\n## [Unreleased]\n".length);
      const next = after.search(/^## /m);
      unreleased = bulletsOf(next < 0 ? after : after.slice(0, next));
      rest = next < 0 ? "" : after.slice(next);
    }
    const m = rest.match(/^## \[(\d+\.\d+\.\d+)\][^\n]*\n([\s\S]*?)(?=^## |$(?![\s\S]))/m);
    const top = m?.[1] ?? null;
    const bullets = bulletsOf(m?.[2] ?? "").length;
    const w: Gate = { ...g, state: "waiting" };
    if (unreleased.length > 0) return { ...w, detail: "Unreleased holds " + unreleased.length + " bullets above " + (top ?? "the top") + ": cut the release commit first", tail: unreleased.map((l) => l.match(/^- \*\*(.+?)\*\*/)?.[1] ?? l.slice(2)) };
    if (top === null) return { ...w, detail: "no numbered version heading on " + branch };
    if (top !== base) return { ...w, detail: "the top section is " + top + ", not " + base };
    if (bullets === 0) return { ...w, detail: base + " has no bullet" };
    if (tags.has("v" + version)) return { ...w, detail: "v" + version + " is tagged already" };
    return { ...g, state: "done", detail: base + " on top, " + bullets + " bullets", proof: base + " on top" };
  }

  function gateHold(): Gate {
    const g: Gate = { id: "hold", name: "No peer release", state: "idle", detail: NO_REPORT + ": config.toml names no hold file" };
    if (cfg.hold === "") return g;
    if (!existsSync(cfg.hold)) return { ...g, state: "done", detail: "no hold file", proof: "no hold file" };
    return { ...g, state: "waiting", detail: clip("hold: " + ((readFileSync(cfg.hold, "utf8").trim().split("\n")[0] ?? "") || "a peer release is in flight"), 200) };
  }

  function gateCounsel(): Gate {
    const g: Gate = { id: "counsel", name: "Counsel done", state: "idle", detail: NO_REPORT };
    if (cfg.counsel === "" || !existsSync(cfg.counsel)) return g;
    const at = statSync(cfg.counsel).mtimeMs;
    if (newestTag !== null && at <= newestTag.at) return { ...g, state: "waiting", detail: "the counsel note is older than " + newestTag.name };
    if (!readFileSync(cfg.counsel, "utf8").includes(version)) return { ...g, state: "waiting", detail: "the counsel note does not name " + version };
    return { ...g, state: "done", detail: "counsel note, " + day(at), proof: "note of " + day(at) };
  }

  // ── Run the gates ──
  let gates: Gate[];
  let asOf = now;
  let ciUrl = "";
  if (fixture === "all-green") {
    const names = ["CI on " + branch, "Browser leg", "Core legs", "Windows rehearsal", "Changelog", "No peer release", "Counsel done"];
    gates = names.map((name, i) => ({ id: String(i), name, state: "done", detail: "fixture: forced green", proof: "forced green" }));
  } else {
    const [ci, changelog] = await Promise.all([gateCi(), gateChangelog()]);
    asOf = ci.at;
    ciUrl = ci.url;
    gates = [ci.gate, gateLeg(), gateCore(), gateWindows(), changelog, gateHold(), gateCounsel()];
  }
  const green = gates.filter((g) => g.state === "done").length;
  const allGreen = green === 7;
  const tagKey = "tag-" + version.replace(/[^a-z0-9]+/g, "-");
  const release = t.sessionNamed(releaseSession);
  const notes: string[] = [];

  // ── An answer: tag or not-yet. The trick never tags; a yes is a record. ──
  const tap = t.tap;
  if (tap !== null && tap.decision === tagKey) {
    const { rid, seen } = tap;
    if (rid === "") notes.push("A tap with no request id was not recorded.");
    else if (tap.intent === "tag" && !allGreen) notes.push("Not recorded: " + green + " of 7 gates are green.");
    else if (tap.intent === "tag") notes.push(yesLog.once(rid, { rid, at: iso(now), version, answer: "yes", fixture: fixture || null, seen }) ? "Yes for v" + version + " recorded." : "This tap was recorded already.");
    else if (tap.intent === "not-yet") {
      t.closedUntil(tagKey, now + DAY_MS);
      notes.push("The tag of v" + version + " is closed for 24 h.");
    } else if (tap.intent === "dismiss") {
      const fresh = dismissed.once(rid, { rid, at: iso(now), version, seen });
      if (fresh) t.closedUntil(tagKey, now + DAY_MS);
      notes.push(fresh ? "The Decision to tag v" + version + " is dismissed, closed for 24 h." : "This tap was recorded already.");
    }
  }
  const yes = yesLog.all().find((r) => r.version === version);
  const asking = allGreen && yes === undefined && t.isClosed(tagKey) === null;

  // ── The places and the Session: the first red gate on top, with its log tail ──
  const firstRed = gates.find((g) => g.state === "waiting");
  const tone: Tone = allGreen ? "ok" : firstRed !== undefined ? "danger" : "muted";
  t.put(show, { label: "Gates", icon: "tag", badge: green + "/7", word: "gates " + green + "/7", tone });
  const chips = (withCurrent: boolean): Node => v.bar(gates.map((g, i) => v.chip(String(i + 1), { state: g.state, ...(g.state === "waiting" ? { tone: "danger" as const } : {}), ...(withCurrent && g === firstRed ? { current: true } : {}) })), { label: "Gates" });
  const view: Node[] = [v.number(green + "/7", { label: "gates green for v" + version, tone }), ...notes.map((n) => v.line(clip(n, 240), { role: "status" }))];
  if (firstRed !== undefined) {
    view.push(v.card([v.para(clip("First red gate: " + firstRed.name, 200), { role: "heading" }), v.line(clip(firstRed.detail, 240), { role: "note" })], { tone: "danger" }));
    const tail = (firstRed.tail ?? []).slice(-40).map((l) => clip(l, 240)).filter((l) => l !== "");
    if (tail.length > 0) view.push(v.code(tail.join("\n"), { lang: "text", max: 8 }));
  }
  view.push(chips(true));
  view.push(v.list(gates.map((g, i) => v.row(clip(i + 1 + " " + g.name, 120), { end: STATE_WORD[g.state], tone: STATE_TONE[g.state] }, [v.para(clip(g.detail || NO_REPORT, 400))]))));
  if (yes !== undefined) view.push(v.line(clip("Yes given for v" + version + ", " + minute(Date.parse(yes.at)) + ". " + (release !== null ? "The release session tags and pushes." : "No session named " + releaseSession + " in the facts: pass the yes on yourself."), 240), { role: "note" }));
  const nowhere = "No session is named " + releaseSession + ", so the Decision has no replyTo and your answer reaches no release session.";
  if (asking && release === null) view.push(v.list([v.row("answers are recorded here only", { tone: "muted" }, [v.para(clip(nowhere, 400))])]));
  if (fixture !== "") view.push(v.line(clip("fixture: " + fixture + ", the gates are not read", 240), { role: "note" }));
  const subtitle = "v" + version + ": " + green + " of 7 green" + (firstRed !== undefined ? ", first red: " + firstRed.name : "");
  const reds = gates.filter((g) => g.state === "waiting").length;
  t.session({ subtitle: clip(subtitle, 120), progress: { value: green, max: 7 }, ...(reds > 0 ? { badge: { count: reds } } : {}), view });
  t.asOf(asOf);

  // ── The Decision, only when all seven are green ──
  if (!asking) return;
  // The CI row opens the run on GitHub; the card shows the host.
  const ciLink = (i: number) => (i === 0 && ciUrl.startsWith("https://") && ciUrl.length <= 500 ? { href: ciUrl } : {});
  const proof: Node[] = [chips(false), v.list(gates.map((g, i) => v.row(clip(i + 1 + " " + g.name, 120), { end: clip(g.proof ?? g.detail, 24), tone: "ok", ...ciLink(i) })))];
  const table = ["| Gate | State | Detail |", "| --- | --- | --- |", ...gates.map((g, i) => "| " + (i + 1) + " " + g.name + " | green | " + clip(g.detail, 120).replace(/\|/g, "/") + " |")].join("\n");
  t.decide({
    key: tagKey,
    // The act and the thing (HILL_WRITING); the summary: what the yes does, then the fact that decides it.
    title: "Tag and push v" + version + "?",
    summary: "Your yes goes to the release session, which tags and pushes v" + version + ". All seven gates are green.",
    body: table,
    options: [
      { intent: "tag", label: "Tag and push", detail: "Your yes goes to the release session, which tags and pushes.", confirm: ["Tap again: tag v" + version, "Again: tag v" + version, "Again: v" + version].find((s) => s.length <= 24) ?? "Tap again: tag" },
      { intent: "not-yet", label: "Hold for 24 h", detail: "Asks again after 24 h." },
    ],
    recommends: { intent: "tag", why: "All seven gates are green." },
    text: "none",
    priority: "now",
    view: proof,
    ...(release === null ? {} : { about: release.id, replyTo: release.id }),
  });
});
