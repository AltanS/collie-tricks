// The Design Review trick: the yes by name for UI changes. A worker keeps LOOK.md and .look/ (the shots) at the root
// of its worktree, out of git. Design Review finds each root under `roots` in config.toml, asks one Decision per line
// with its shots, and keeps each answer as a dated line in given.jsonl in its state folder (the audit).
// LOOK.md, one line per visible change:  - <name> | <route or screen> | <one sentence> | <shot> [| <before shot>] [| suggest <yes|no|change>: <why>]
// The trick has no opinion of its own. A worker may add the optional last field `suggest <answer>: <why>`
// (strict: yes, no or change, a colon, a reason of 1 to 200 characters). It becomes the Decision's `recommends`
// with the worker's name in the why ("From <session>: <why>"), so the card never says the trick advises it.
//
// Asked again: an answer drops the key; a changed line or shot gives it a new hash, so the list holds it
// again. A dismiss closes the key for 24 h. git runs read only (branch, check-ignore, status), cached 60 s.
// Everything else is Collie's helper, trick.ts (v3): the records, the cache, the tool lookup, `show`.
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { basename, extname, join } from "node:path";

import { DAY_MS, MINUTE_MS, age, clip, iso, mapText, mask, minute, now as clock, run, v, type Node, type Trick } from "./trick.ts";

const SHOT_HARD_MAX = 2 * 1024 * 1024;
const SHOT_MAX = 512 * 1024;
const ANSWERS = ["yes", "no", "change"];
const SUGGEST_REASON_MAX = 200;
/** A field that tries to be a suggest field (one word "suggest", then a space, a colon or the end), strict or not. */
const SUGGEST_START = /^suggest(\s|:|$)/i;
/** The strict form: `suggest yes: why`, `suggest no: why`, `suggest change: why`; the reason is 1 to 200 characters. */
const SUGGEST_FORM = /^suggest (yes|no|change): (\S.*)$/;
/** The suggest field of a line: the answer and the reason, or null when it is not in the strict form. */
function parseSuggest(field: string): Suggest | null {
  const m = field.match(SUGGEST_FORM);
  const reason = m?.[2]?.trim() ?? "";
  if (m === null || reason === "" || reason.length > SUGGEST_REASON_MAX) return null;
  return { intent: m[1] ?? "", reason };
}

interface Suggest { intent: string; reason: string }
interface Change { key: string; hash: string; branch: string; root: string; name: string; route: string; sentence: string; shots: string[]; at: number; media: { file: string; caption: string }[]; problem: string | null; suggest: Suggest | null; suggestBad: boolean }
interface Given { at: string; rid: string; key: string; branch: string; name: string; answer: string; text: string | null; hash: string; seen: string | null }
interface GitInfo { git: boolean; branch: string; exposed: string[] }
/** One masked line on stderr: what `collie trick check` and the bridge's error line show. */
const doctor = (line: string): void => void process.stderr.write("doctor: " + clip(line, 200) + "\n");
const str = (value: unknown, fallback = ""): string => (typeof value === "string" ? value : fallback);
/** No em dash on screen, a comma instead, and never a longer string: "a—b" is "a,b", "a — b" is "a, b". */
const noDash = (text: string): string => text.replace(/\s*—\s*/g, (m) => (m.length > 1 ? ", " : ","));

/** Every folder under the globs of `roots` that holds a LOOK.md. */
function findRoots(t: Trick, patterns: string[]): string[] {
  const out = new Set<string>();
  for (const pattern of patterns) {
    const segs = t.path(pattern).split("/");
    const first = segs.findIndex((s) => /[*?[{]/.test(s));
    const base = first < 0 ? segs.join("/") : segs.slice(0, first).join("/") || "/";
    const hits = first < 0 ? [base] : existsSync(base) ? [...new Bun.Glob(segs.slice(first).join("/")).scanSync({ cwd: base, onlyFiles: false, absolute: true })] : [];
    for (const hit of hits) if (existsSync(join(hit, "LOOK.md"))) out.add(hit);
  }
  return [...out].sort();
}

/** The branch, and which of LOOK.md and .look/ git would commit. */
async function readGit(t: Trick, git: string, root: string): Promise<GitInfo> {
  const sh = (...args: string[]) => t.sh(git, ["-C", root, ...args], { timeoutMs: 3000 });
  if (!(await sh("rev-parse", "--is-inside-work-tree")).ok) return { git: false, branch: "", exposed: [] };
  const [branch, ignored, status] = await Promise.all([sh("branch", "--show-current"), sh("check-ignore", "LOOK.md", ".look/"), sh("status", "--porcelain", "--", "LOOK.md", ".look")]);
  const ignoredSet = new Set(ignored.stdout.split("\n").map((l) => l.trim().replace(/\/$/, "")));
  const exposed = ["LOOK.md", ".look"].filter((e) => !ignoredSet.has(e));
  // A file already tracked or staged is exposed whatever the ignore rules say.
  for (const line of status.stdout.split("\n")) if (line.slice(3).trim() !== "" && !line.startsWith("??") && !exposed.includes(line.slice(3).trim())) exposed.push(line.slice(3).trim());
  return { git: true, branch: branch.ok ? branch.stdout.trim() : "", exposed };
}

function shotProblem(file: string): string | null {
  if (!existsSync(file)) return "no shot: " + basename(file) + " is not under .look/";
  if (!/\.(png|jpe?g)$/i.test(file)) return "the shot is not a PNG";
  const size = statSync(file).size;
  if (size > SHOT_HARD_MAX) return "the shot is " + (size / 1048576).toFixed(1) + " MB, over 2 MB";
  if (size > SHOT_MAX) return "the shot is " + Math.round(size / 1024) + " KB, over the 512 KB Design Review takes";
  const head = readFileSync(file).subarray(0, 8).toString("hex");
  return head.startsWith("89504e470d0a1a0a") || head.startsWith("ffd8ff") ? null : "the shot is not a PNG or JPEG";
}

/** One Change per `- ` line of each LOOK.md, with a problem when it cannot be asked. */
function readChanges(roots: string[], git: Map<string, GitInfo>): Change[] {
  return roots.flatMap((root) => {
    const text = readFileSync(join(root, "LOOK.md"), "utf8");
    const branch = git.get(root)?.branch || text.match(/^#\s*LOOK\s+(\S+)/m)?.[1] || basename(root);
    return text.split(/\r?\n/).filter((l) => l.startsWith("- ")).map((line): Change => {
      const all = line.slice(2).split("|").map((f) => f.trim());
      // The suggest field starts at the first field from the fifth on that says `suggest`; the rest of the line is its reason.
      const sAt = all.findIndex((f, i) => i >= 4 && SUGGEST_START.test(f));
      const fields = sAt < 0 ? all : all.slice(0, sAt);
      const suggestField = sAt < 0 ? null : all.slice(sAt).join(" | ");
      const suggest = suggestField === null ? null : parseSuggest(suggestField);
      const [name = "", route = "", sentence = "", shot = "", before = ""] = fields;
      const slug = (s: string, max: number) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, max).replace(/-+$/, "") || "x";
      const shots = [shot, before].filter((f) => f !== "").map((f) => join(root, f.startsWith(".look/") ? "" : ".look", f));
      const hasher = new Bun.CryptoHasher("sha256").update(line);
      for (const f of shots) if (existsSync(f)) hasher.update(readFileSync(f));
      const c: Change = { key: (slug(branch, 24) + "-" + slug(name, 40)).slice(0, 64).replace(/-+$/, ""), hash: hasher.digest("hex").slice(0, 12), branch, root, name, route, sentence, shots, at: 0, media: [], problem: null, suggest, suggestBad: suggestField !== null && suggest === null };
      if (fields.length < 4 || fields.length > 5 || name === "" || route === "" || sentence === "") c.problem = "a line needs name | route | sentence | shot, then an optional before shot and an optional suggest field";
      else if (shot === "") c.problem = "no shot: the line names no file under .look/";
      else if ([shot, before].some((f) => f.includes(".."))) c.problem = "a shot name may not climb out of .look/";
      else c.problem = shots.map(shotProblem).find((p) => p !== null) ?? null;
      if (c.problem === null) c.at = statSync(shots[0] ?? "").mtimeMs;
      else doctor("not asked, " + branch + ": " + (name || "a line") + ": " + c.problem);
      return c;
    });
  });
}

/** The hill takes images from the trick folder only: each shot is copied to media/, and stale copies go. */
function placeMedia(dir: string, changes: Change[]): void {
  const mediaDir = join(dir, "media");
  const keep = new Set<string>();
  for (const c of changes.filter((x) => x.problem === null)) {
    try {
      mkdirSync(mediaDir, { recursive: true });
      c.shots.forEach((shot, i) => {
        const target = c.key + "-" + c.hash + (i === 0 ? "" : "-before") + extname(shot).toLowerCase();
        keep.add(target);
        if (!existsSync(join(mediaDir, target))) copyFileSync(shot, join(mediaDir, target));
        c.media.push({ file: "media/" + target, caption: i === 0 ? "After" : "Before" });
      });
    } catch (e) {
      c.problem = "the shot cannot be copied into the trick folder: " + (e instanceof Error ? e.message : String(e));
      c.media = [];
    }
  }
  if (existsSync(mediaDir)) for (const f of readdirSync(mediaDir)) if (!keep.has(f)) rmSync(join(mediaDir, f), { force: true });
}

run(async (t) => {
  // Every string the phone gets is masked (keys, the home folder) and carries no em dash.
  t.onPrint((doc) => mapText(doc, (s) => noDash(mask(s))));
  const now = clock();
  // SAFETY: an optional [design-review] table holds the same keys as the top level.
  const cfg = (typeof t.config["design-review"] === "object" ? t.config["design-review"] : t.config) as Trick["config"];
  const lane = str(cfg.lane, "").replace(/\/+$/, "");
  const replySession = str(cfg.reply_session, "");
  const show = t.show(["dashboard"], cfg);
  if (cfg.mark !== undefined) t.configWarn('mark is gone: write show = ["dashboard"] instead');
  const roots = findRoots(t, Array.isArray(cfg.roots) ? cfg.roots.map(String) : []);
  const given = t.log<Given>("given");
  const dismissed = t.log("dismissed");

  // ── git, read only and cached; a tap never waits on it ──
  const gitPath = t.tool("git");
  const git = new Map<string, GitInfo>();
  const warnRows: { text: string; detail: string }[] = [];
  if (gitPath === null && roots.length > 0) warnRows.push({ text: "git not found", detail: "the branch names come from LOOK.md headings, and the out-of-git check is off" });
  let gitAt = now;
  for (const root of gitPath === null ? [] : roots) {
    const name = "git-" + basename(root).replace(/[^A-Za-z0-9-]+/g, "-").slice(0, 30) + "-" + Bun.hash(root).toString(36).slice(0, 8);
    const read = await t.cached("cache-" + name, t.tap !== null ? Infinity : MINUTE_MS, () => readGit(t, gitPath ?? "git", root));
    if (read.value !== null) git.set(root, read.value);
    gitAt = Math.min(gitAt, read.at);
    const info = read.value;
    if (info === null || !info.git || info.exposed.length === 0) continue;
    warnRows.push({ text: info.exposed.join(" and ") + " would be committed (" + (info.branch || basename(root)) + ")", detail: "Add LOOK.md and .look/ to the worktree's info/exclude (git rev-parse --git-path info/exclude)." });
    doctor(info.exposed.join(" and ") + " would be committed in " + root);
  }

  const changes = readChanges(roots, git);
  placeMedia(t.facts.trick.dir, changes);
  const offered = t.state.get<Record<string, string>>("offered", {});
  const notes: string[] = [];

  // ── An answer: one dated line per rid in given.jsonl, for the hash the Decision showed ──
  const tap = t.tap;
  if (tap !== null && tap.decision !== null && (ANSWERS.includes(tap.intent) || tap.intent === "dismiss")) {
    const change = changes.find((c) => c.key === tap.decision && c.problem === null);
    const { rid } = tap;
    const seen = tap.seen;
    if (rid === "") notes.push("A tap with no request id was not recorded.");
    else if (given.has(rid) || dismissed.has(rid)) notes.push("This tap was recorded already.");
    else if (change === undefined) notes.push("That change is no longer listed, so the answer was not recorded.");
    else if (tap.intent === "dismiss") {
      dismissed.once(rid, { rid, at: iso(now), key: change.key, branch: change.branch, name: change.name, hash: offered[change.key] ?? change.hash, seen });
      t.closedUntil(change.key + "@" + change.hash, now + DAY_MS);
      notes.push("Dismissed " + change.name + ", closed for 24 h.");
    } else {
      const shown = offered[change.key];
      const text = tap.text?.trim() ? tap.text.trim().slice(0, 4000) : null;
      given.once(rid, { at: iso(now), rid, key: change.key, branch: change.branch, name: change.name, answer: tap.intent, text, hash: shown ?? change.hash, seen });
      notes.push(tap.intent + " given for " + change.name + "." + (shown !== undefined && shown !== change.hash ? " The line or the shot changed since it was shown, so it is asked again." : ""));
    }
  }

  const latest = new Map(given.all().map((g) => [g.key, g]));
  const answered = (c: Change) => latest.get(c.key)?.hash === c.hash;
  const closedNow = (c: Change) => t.isClosed(c.key + "@" + c.hash) !== null;
  const askable = changes.filter((c) => c.problem === null && !answered(c));
  const waiting = askable.filter((c) => !closedNow(c));
  const posted = waiting.slice(0, 20);
  t.state.set("offered", Object.fromEntries(posted.map((c) => [c.key, c.hash])));
  const n = waiting.length;

  // ── The Decisions: replyTo the worker in the root, else the session named reply_session, else none ──
  const named = replySession === "" ? null : t.sessionNamed(replySession);
  const workerOf = (root: string) => t.facts.sessions.find((s) => s.cwd !== undefined && (s.cwd === root || s.cwd.startsWith(root + "/"))) ?? null;
  for (const c of posted) {
    const worker = workerOf(c.root);
    const to = worker ?? named;
    // A route that is a path opens on the lane: the Where row carries the address, and the card shows its host.
    const open = lane !== "" && c.route.startsWith("/") && (lane + c.route).length <= 500 ? { href: lane + c.route } : {};
    const view: Node[] = [v.row("Where", { end: clip(c.route, 24), ...open }), v.row("Branch", { end: clip(c.branch, 24) }), v.row("Session", { end: clip(to?.name ?? to?.paneId ?? "none", 24) })];
    t.decide({
      key: c.key,
      // The decision itself, by name, in at most 60 characters (HILL_WRITING): the quotes keep the worker's name whole.
      title: "Ship \u201c" + clip(c.name, 50) + "\u201d?",
      summary: clip(c.sentence, 280),
      options: [
        { intent: "yes", label: "Ship it", detail: "The change may ship as the shot shows it." },
        { intent: "no", label: "Keep the old look", detail: "The worker takes the change out of the branch." },
        { intent: "change", label: "Ask for a change", detail: "Say what to change; your words go with the answer." },
      ],
      // The advice is the worker's, never the trick's: the why names who gives it. Only a session at the root is known to be the worker.
      ...(c.suggest === null ? {} : { recommends: { intent: c.suggest.intent, why: clip("From " + (worker?.name ? clip(worker.name, 40) : "the branch's worker") + ": " + c.suggest.reason, 200) } }),
      text: "optional",
      priority: "today",
      media: c.media,
      // Two shots: the before and the new one side by side, cropped alike (media 0 is the new shot, 1 the before).
      view: c.media.length === 2 ? [v.beforeAfter(1, 0), v.group(view)] : [v.group(view)],
      ...(to === null ? {} : { replyTo: to.id }),
    });
  }

  // ── The places and the Session ──
  t.put(show, { label: "Design", icon: "eye", badge: n, word: n > 0 ? "design " + n : null, tone: "accent" });
  const view: Node[] = [v.number(n, { label: "waiting for your yes", tone: n > 0 ? "accent" : "ok" }), ...notes.map((note) => v.line(clip(note, 240), { role: "status" }))];
  if (n > 0) {
    const rows = [...waiting].sort((a, b) => a.branch.localeCompare(b.branch)).slice(0, 23).map((c) => v.row(clip(c.name, 120), { end: age(now - c.at), icon: "eye" }, [v.para(clip(c.branch, 120))]));
    view.push(v.group(n > 23 ? [...rows, v.para("and " + (n - 23) + " more")] : rows, { label: "Waiting", badge: n }));
  }
  const recent = [...latest.values()].filter((g) => (changes.find((c) => c.key === g.key)?.hash ?? g.hash) === g.hash).reverse().slice(0, 20);
  if (recent.length > 0) {
    const rows = recent.map((g) => v.row(clip(g.name, 120), { end: g.answer + ", " + g.at.slice(0, 10), tone: g.answer === "yes" ? "ok" : "warn", icon: g.answer === "yes" ? "check" : "edit" }, g.text === null ? undefined : [v.para(clip(g.text, 400))]));
    view.push(v.group(rows, { label: "Given", badge: recent.length }));
  }
  for (const c of askable.filter(closedNow)) view.push(v.line(clip("Dismissed: " + c.name + ", closed until " + minute(t.isClosed(c.key + "@" + c.hash) ?? now) + ".", 240), { role: "note" }));
  // A suggest field that is not in the strict form is ignored: the change is still asked, and one warn row says so.
  const badSuggest = waiting.filter((c) => c.suggestBad);
  for (const c of badSuggest) doctor("suggest field not understood, " + c.branch + ": " + c.name);
  if (badSuggest.length > 0) {
    const rows = badSuggest.slice(0, 23).map((c) => v.row(clip("suggest field not understood (" + c.name + ")", 120), { tone: "warn", icon: "warn" }, [v.para(clip("Write | suggest yes: <why>, no or change, with a reason of 1 to 200 characters. Design Review ignores the field and asks the change as it is.", 400))]));
    view.push(v.group(badSuggest.length > 23 ? [...rows, v.para("and " + (badSuggest.length - 23) + " more")] : rows, { label: "Suggest field", badge: badSuggest.length }));
  }
  const warn = [...changes.filter((c) => c.problem !== null).map((c) => ({ text: (c.name || "a line") + " (" + c.branch + ")", detail: c.problem ?? "" })), ...warnRows];
  if (warn.length > 0) {
    const rows = warn.slice(0, 23).map((w) => v.row(clip(w.text, 120), { tone: "warn", icon: "warn" }, [v.para(clip(w.detail, 400))]));
    view.push(v.group(warn.length > 23 ? [...rows, v.para("and " + (warn.length - 23) + " more")] : rows, { label: "Not asked", badge: warn.length }));
  }
  if (roots.length === 0) view.push(v.para("No LOOK.md under the roots in config.toml."));
  else if (changes.length === 0) view.push(v.para("The LOOK.md files list no change yet."));
  const lonely = posted.filter((c) => (workerOf(c.root) ?? named) === null).length;
  const why = "No session's folder is the branch root" + (replySession === "" ? ", and config.toml names no reply_session." : ", and no session is named " + replySession + ".");
  if (lonely > 0) view.push(v.list([v.row("answers are recorded here only", { tone: "muted" }, [v.para(clip(why + " " + lonely + " of " + posted.length + " have no one to tell.", 400))])]));
  const branches = [...new Set(waiting.map((c) => c.branch))].join(", ");
  t.session({ subtitle: clip(n > 0 ? n + " waiting on " + branches : roots.length === 0 ? "no LOOK.md found" : "nothing waiting", 120), ...(n > 0 ? { badge: { count: n } } : {}), view });
  t.asOf(gitAt);
  t.fresh("15m");
});
