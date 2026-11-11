// The PR Inbox trick: public replies on the operator's own login, one Decision each. It reads the open PRs and
// issues of `repo` with gh (read only, cached 60 s) and offers each draft in `drafts` that passes the house
// check. A draft that fails the check is a card in the Session with its failing line, never a Decision.
//
// The act. With live = false a Post tap only writes a would record with the tap's rid: no gh write runs.
// With live = true a Post runs gh pr comment (or gh issue comment) once per rid. Merge has no live path: it
// always writes a record. Edit keeps the person's words in the state folder (they reach the drafting agent
// through replyTo); Hold, Not yet and a dismiss close the key for 24 h.
// Asked again: a post or a would-merge ends the key for that draft; a new draft text is new content.
// The records, the cache, the tool lookup and `show` are Collie's helper, trick.ts (v4); lib.ts is the house check.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

import { DAY_MS, MINUTE_MS, age, clip, firstSentence, iso, mapText, mask, minute, now as clock, run, v, type Node, type Tone } from "./trick.ts";
import { HOUSE_RULES, checkDraft, clipBlock, hideNames } from "./lib.ts";

type Ci = "green" | "red" | "running" | "none";
interface Item { kind: "pr" | "issue"; number: number; title: string; url: string; createdAt: string; ci: Ci; draft: boolean }
interface Comment { login: string; at: string; bot: boolean; body?: string }
interface Draft { number: number; file: string; text: string; hash: string; mtime: number; verdict: string | null }
interface PostRecord { rid: string; number: number; hash: string; state: "would" | "started" | "posted" | "failed"; url?: string; why?: string; at: string; repo?: string; seen: string | null }
interface MergeRecord { rid: string; number: number; at: string; repo: string; into: string; hash: string; seen: string | null }
const CI_TONE: Record<Ci, Tone> = { green: "ok", red: "danger", running: "accent", none: "muted" };
/** One masked line on stderr: what `collie trick check` and the bridge's error line show. */
const doctor = (line: string): void => void process.stderr.write("doctor: " + clip(line, 200) + "\n");
const str = (value: unknown, fallback = ""): string => (typeof value === "string" ? value : fallback);
/** No em dash on screen, a comma instead (the house rule), and never a longer string: "a—b" is "a,b", "a — b" is "a, b". */
const noDash = (text: string): string => text.replace(/\s*—\s*/g, (m) => (m.length > 1 ? ", " : ","));

function ciOf(rollup: unknown): Ci {
  const checks = Array.isArray(rollup) ? (rollup as Record<string, string | null>[]) : [];
  if (checks.length === 0) return "none";
  let running = false;
  for (const c of checks) {
    const word = (c.conclusion || c.state || "").toUpperCase();
    const status = (c.status || "").toUpperCase();
    if (["FAILURE", "CANCELLED", "TIMED_OUT", "ERROR", "ACTION_REQUIRED", "STARTUP_FAILURE"].includes(word)) return "red";
    if (word === "" || word === "PENDING" || word === "EXPECTED" || (status !== "" && status !== "COMPLETED")) running = true;
  }
  return running ? "running" : "green";
}

/**
 * The advice on a reply Decision, from facts this run read: only a draft that passed the house check gets a
 * Decision, so the check always holds here. An issue has no CI: Post. A PR with green CI: Post. Red CI or CI
 * that still runs: Hold, with the reason. A PR with no CI at all: no advice. Advice only, never pre-selected.
 */
function advise(item: Item): { recommends?: { intent: string; why: string } } {
  if (item.kind === "issue") return { recommends: { intent: "post", why: "The house check passes." } };
  if (item.ci === "green") return { recommends: { intent: "post", why: "The house check passes and CI is green." } };
  if (item.ci === "red") return { recommends: { intent: "hold", why: "CI is red on this pull request." } };
  if (item.ci === "running") return { recommends: { intent: "hold", why: "CI still runs." } };
  return {};
}

/** The PR or issue's own title, short: the conventional prefix (`fix(core): `) dropped. */
function shortTitle(title: string): string {
  return title.replace(/^[a-z]+(\([^)]*\))?!?:\s*/i, "").trim();
}

/** `text` masked on one line, cut at a word to at most `max` characters with "…", so a cut word never shows. */
function clipWords(text: string, max: number): string {
  const one = clip(text, 10_000);
  if (one.length <= max) return one;
  const cut = one.slice(0, max - 1);
  const space = cut.lastIndexOf(" ");
  return (space > max / 2 ? cut.slice(0, space) : cut).replace(/[\s,;:.]+$/, "") + "\u2026";
}

/**
 * A Decision's title, at most 60 characters (HILL_WRITING): the act and the item, with the item's own title in
 * brackets when it fits, such as `Merge PR 14 (use the plain spawn for the ...)?`. Dry run is said in the summary.
 */
function titleFor(act: string, item: Item): string {
  const room = 60 - act.length - 4;
  const name = shortTitle(item.title);
  return room >= 12 && name !== "" ? act + " (" + clipWords(name, room) + ")?" : act + "?";
}

function readDrafts(dir: string): Draft[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir).sort().flatMap((f) => {
    const m = f.match(/^(\d{1,7})\.md$/);
    if (!m) return [];
    const number = Number(m[1]);
    const file = join(dir, f);
    const text = readFileSync(file, "utf8").trim();
    const vfile = join(dir, number + ".verdict");
    return [{ number, file, text, hash: Bun.hash(text).toString(36).slice(0, 12), mtime: statSync(file).mtimeMs, verdict: existsSync(vfile) ? readFileSync(vfile, "utf8").trim() : null }];
  });
}
/** What a merge Decision showed: the draft and the verdict beside it. The guard compares these bytes. */
const mergeHash = (d: Draft): string => Bun.hash(d.text + "\n--\n" + (d.verdict ?? "")).toString(36).slice(0, 12);

run(async (t) => {
  // Every string the phone gets is masked (keys, the home folder) and carries no em dash, also text from GitHub.
  t.onPrint((doc) => mapText(doc, (s) => noDash(mask(s))));
  const now = clock();
  const repo = str(t.config.repo);
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) throw new Error("config.toml: repo must be owner/name");
  const draftsDir = t.path(str(t.config.drafts, "drafts"));
  const live = t.config.live === true;
  const replySession = str(t.config.reply_session, "");
  const show = t.show(["dashboard"]);
  if (t.config.mark !== undefined) t.configWarn('mark is gone: write show = ["dashboard"] instead');
  const gh = t.tool("gh");
  const posts = t.log<PostRecord>("posts");
  const edits = t.log("edits");
  const wouldMerge = t.log<MergeRecord>("would-merge");
  const dismissed = t.log("dismissed");
  const notes: string[] = [];
  const first = (text: string, fallback: string): string => (text.trim().split("\n")[0] ?? "").trim() || fallback;
  const sh = async (cmd: string, args: string[], timeoutMs: number) => {
    const r = await t.sh(cmd, args, { timeoutMs });
    return { ok: r.ok, out: r.stdout, err: r.code === 143 || r.code === 137 || r.code === null ? "timed out" : r.stderr };
  };
  /** The read verbs this trick may run. Anything else throws before it runs. */
  const ghRead = (args: string[]) => {
    if (!["pr list", "issue list", "api -X"].includes(args[0] + " " + args[1]) || (args[0] === "api" && args[2] !== "GET")) throw new Error("gh " + args.slice(0, 3).join(" ") + " is not a read");
    return sh(gh ?? "gh", args, 7000);
  };

  // The operator's names, for the check: config.toml names, else the words of git's user.name.
  let names = Array.isArray(t.config.names) ? t.config.names.map(String).filter((n) => n.length >= 3) : [];
  const git = names.length === 0 ? t.tool("git") : null;
  if (git !== null) names = (await sh(git, ["config", "--global", "user.name"], 3000)).out.split(/\s+/).filter((s) => s.length >= 3);
  let drafts = readDrafts(draftsDir);
  if (!existsSync(draftsDir)) doctor("no drafts folder at " + draftsDir);

  // ── GitHub, read only, cached 60 s; a tap takes the kept copy at any age, so it never waits on the network ──
  const noGh = "gh not found on PATH or in the usual places";
  const ttl = (ms: number): number => (t.tap !== null ? Infinity : ms);
  const [open, login, ...threads] = await Promise.all([
    t.cached<{ items: Item[] }>("cache-open", ttl(MINUTE_MS), async () => {
      if (gh === null) throw new Error(noGh);
      const [prs, issues] = await Promise.all([
        ghRead(["pr", "list", "-R", repo, "--state", "open", "--limit", "50", "--json", "number,title,createdAt,isDraft,statusCheckRollup,url"]),
        ghRead(["issue", "list", "-R", repo, "--state", "open", "--limit", "50", "--json", "number,title,createdAt,url"]),
      ]);
      if (!prs.ok || !issues.ok) throw new Error("gh read failed: " + clip(first(prs.ok ? issues.err : prs.err, "no reason given"), 160));
      const items: Item[] = [];
      for (const p of JSON.parse(prs.out) as Record<string, unknown>[]) items.push({ kind: "pr", number: Number(p.number), title: String(p.title), url: String(p.url), createdAt: String(p.createdAt), ci: ciOf(p.statusCheckRollup), draft: p.isDraft === true });
      for (const i of JSON.parse(issues.out) as Record<string, unknown>[]) items.push({ kind: "issue", number: Number(i.number), title: String(i.title), url: String(i.url), createdAt: String(i.createdAt), ci: "none", draft: false });
      return { items };
    }),
    t.cached<string>("cache-login", ttl(DAY_MS), async () => {
      if (gh === null) throw new Error(noGh);
      const r = await ghRead(["api", "-X", "GET", "user", "--jq", ".login"]);
      if (!r.ok || r.out.trim() === "") throw new Error("gh api user failed");
      return r.out.trim();
    }),
    ...drafts.map((d) =>
      t.cached<Comment[]>("cache-thread-" + d.number, ttl(MINUTE_MS), async () => {
        if (gh === null) throw new Error(noGh);
        const r = await ghRead(["api", "-X", "GET", "repos/" + repo + "/issues/" + d.number + "/comments", "-f", "per_page=100"]);
        if (!r.ok) throw new Error("the comments of #" + d.number + " cannot be read");
        const raw = JSON.parse(r.out) as { user?: { login?: string; type?: string }; created_at?: string; body?: string }[];
        return raw.map((c) => ({ login: c.user?.login ?? "", at: c.created_at ?? "", bot: c.user?.type === "Bot" || (c.user?.login ?? "").endsWith("[bot]"), body: clip(c.body ?? "", 300) }));
      }),
    ),
  ]);
  const items = open.value?.items ?? [];
  const byNumber = new Map(items.map((i) => [i.number, i]));
  const threadOf = new Map(drafts.map((d, i) => [d.number, threads[i]?.value ?? null]));
  const me = login.value;
  const what = (n: number): string => (byNumber.get(n)?.kind === "issue" ? "issue " + n : "PR " + n);
  const offered = t.state.get<Record<string, string>>("offered", {});
  const replyTo = replySession === "" ? null : t.sessionNamed(replySession);

  // ── An answer on the Hill ──
  const tap = t.tap;
  if (tap !== null && tap.decision !== null) {
    const { decision: key, intent, rid, seen } = tap;
    const m = key.match(/^(reply|merge)-(\d+)$/);
    const number = Number(m?.[2] ?? 0);
    const draft = drafts.find((d) => d.number === number);
    const item = byNumber.get(number);
    if (rid === "" || m === null || draft === undefined) notes.push("That Decision is no longer listed, so the tap did nothing.");
    else if (m[1] === "reply" && intent === "post") {
      if (posts.has(rid)) notes.push("This tap was recorded already.");
      else if (offered[key] !== draft.hash) notes.push("The draft for " + what(number) + " is not the one that was shown, so nothing was posted. It is asked again if it passes the check.");
      else if (!live) {
        // live = false: a record and nothing else. No gh write below this line runs.
        posts.once(rid, { rid, number, hash: draft.hash, state: "would", at: iso(now), repo, seen });
        notes.push("Would post to " + what(number) + ", live is off.");
      } else if (gh === null) {
        posts.once(rid, { rid, number, hash: draft.hash, state: "failed", why: "gh not found", at: iso(now), seen });
        notes.push("Not posted: gh not found.");
      } else {
        // Once per rid: the started record goes first, so a killed run never posts twice.
        posts.once(rid, { rid, number, hash: draft.hash, state: "started", at: iso(now), seen });
        const r = await sh(gh, [item?.kind === "issue" ? "issue" : "pr", "comment", String(number), "-R", repo, "--body-file", draft.file], 8000);
        const why = clip(first(r.err, "gh failed"), 160);
        if (r.ok) posts.append({ rid, number, hash: draft.hash, state: "posted", url: r.out.match(/https:\/\/github\.com\/\S+/)?.[0] ?? "", at: iso(now), seen });
        else posts.append({ rid, number, hash: draft.hash, state: "failed", why, at: iso(now), seen });
        notes.push(r.ok ? "Posted to " + what(number) + "." : "Not posted to " + what(number) + ": " + why);
      }
    } else if (m[1] === "reply" && intent === "edit") {
      const words = (tap.text ?? "").trim().slice(0, 4000);
      if (words === "") notes.push("An edit with no words changes nothing. Say what to change.");
      else if (edits.once(rid, { rid, number, hash: draft.hash, at: iso(now), seen, text: words })) {
        t.state.set("edit-" + number, { rid, hash: draft.hash, at: iso(now), seen, text: words });
        notes.push("Your words for " + what(number) + " " + (replyTo === null ? "are kept here: no session is named " + replySession + "." : "went to " + replySession + ", the drafting agent."));
      }
    } else if (m[1] === "reply" && intent === "hold") {
      t.closedUntil(key, now + DAY_MS);
      notes.push("The reply to " + what(number) + " is held for 24 h.");
    } else if (m[1] === "merge" && intent === "merge") {
      if (wouldMerge.has(rid)) notes.push("This tap was recorded already.");
      else if (offered[key] !== mergeHash(draft)) notes.push("The draft or the verdict for PR " + number + " is not the one that was shown, so nothing was recorded. It is asked again if it still approves.");
      else {
        wouldMerge.once(rid, { rid, number, at: iso(now), repo, into: "the base branch", hash: offered[key] ?? "", seen });
        notes.push("Would merge PR " + number + " into the base branch, merge has no live path yet.");
      }
    } else if (intent === "dismiss") {
      if (dismissed.once(rid, { rid, key, number, hash: offered[key] ?? draft.hash, at: iso(now), seen })) {
        t.closedUntil(key, now + DAY_MS);
        t.closedUntil("dismiss:" + key, now + DAY_MS);
        notes.push("Dismissed the " + (m[1] === "merge" ? "merge of PR " + number : "reply to " + what(number)) + ", closed for 24 h.");
      } else notes.push("This tap was recorded already.");
    } else if (m[1] === "merge" && intent === "not-yet") {
      t.closedUntil(key, now + DAY_MS);
      notes.push("The merge of PR " + number + " is closed for 24 h.");
    }
    drafts = readDrafts(draftsDir);
  }

  const postList = posts.all();
  const postOf = (d: Draft) => [...postList].reverse().find((p) => p.number === d.number && p.hash === d.hash);
  const merged = new Set(wouldMerge.all().map((r) => r.number));

  // ── The Decisions, and the cards and lines of the Session ──
  const cards: Node[] = [];
  const lines: string[] = [];
  const done: { text: string; end: string; detail: string; href?: string }[] = [];
  const shown: Record<string, string> = {};
  const answered = new Set<number>();
  const dry = !live;
  const withReply = replyTo === null ? {} : { replyTo: replyTo.id };
  for (const d of drafts) {
    const item = byNumber.get(d.number);
    if (item === undefined) {
      if (open.value !== null) lines.push("The draft for #" + d.number + " waits: #" + d.number + " is not open.");
      continue;
    }
    const people = (threadOf.get(d.number) ?? []).filter((c) => !c.bot);
    const newest = people[people.length - 1];
    if (me !== null && newest !== undefined && newest.login === me) {
      answered.add(d.number);
      continue;
    }
    const moved = people.find((c) => c.login !== me && Date.parse(c.at) > d.mtime);
    const bad = checkDraft(d.text, names) ?? (moved !== undefined ? { why: "the thread moved since this draft", line: "a comment from @" + moved.login + ", " + minute(Date.parse(moved.at)) } : null);
    if (bad !== null) {
      doctor("draft " + d.number + " refused: " + hideNames(bad.why, names));
      cards.push(v.card([v.para(clip("Not offered: the reply to " + what(d.number), 200)), v.line(clip("fails the check: " + hideNames(bad.why, names), 240), { role: "note" }), v.para(clip(hideNames(bad.line, names), 400), { role: "quote" })], { tone: "danger" }));
      continue;
    }
    const replyKey = "reply-" + d.number;
    const edit = t.state.get<{ hash: string; at: string; text?: string } | null>("edit-" + d.number, null);
    const post = postOf(d);
    const opened = age(now - Date.parse(item.createdAt));
    if (edit !== null && edit.hash === d.hash) {
      const where = replyTo === null ? "Kept in this trick's records" : "Sent to " + replySession;
      cards.push(v.card([v.para(clip("The reply to " + what(d.number) + " waits for the drafting agent's new version.", 200)), v.para(clip(edit.text ?? "(no words)", 400), { role: "quote" }), v.line(clip(where + ", " + minute(Date.parse(edit.at)) + ".", 240), { role: "note" })], { tone: "accent" }));
    } else if (post?.state === "would") done.push({ text: "Reply to " + what(d.number), end: "would post", detail: "Dry run: nothing was posted, live is off. Recorded " + minute(Date.parse(post.at)) + "." });
    else if (post?.state === "posted") done.push({ text: "Reply to " + what(d.number), end: "posted", detail: "Posted " + minute(Date.parse(post.at)) + ".", ...(post.url ? { href: post.url } : {}) });
    else if (post?.state === "started") lines.push("The post to " + what(d.number) + " did not finish. Look at the thread before you post again.");
    else if (t.isClosed(replyKey) !== null) lines.push((t.isClosed("dismiss:" + replyKey) !== null ? "Dismissed: " : "Held: ") + "the reply to " + what(d.number) + ", until " + minute(t.isClosed(replyKey) ?? now) + ".");
    else {
      if (post?.state === "failed") lines.push("The last post to " + what(d.number) + " failed: " + (post.why ?? "no reason") + ". Tap Post the reply again to retry.");
      shown[replyKey] = d.hash;
      const last = people[people.length - 1];
      const view: Node[] = [
        v.bar(HOUSE_RULES.map((rule) => v.chip(rule, { tone: "ok", icon: "check" })), { label: "House check" }),
        v.bar([v.chip(item.kind === "issue" ? "issue" : item.ci === "none" ? "no CI" : "CI " + item.ci, { tone: CI_TONE[item.ci] }), v.chip("opened " + opened + " ago", { icon: "clock" })], { label: what(d.number) }),
      ];
      if (last?.body) view.push(v.spacer("Last comment"), v.para(clip("@" + last.login + ": " + last.body, 300), { role: "quote" }));
      view.push(v.spacer("The draft"), v.para(clip(d.text, 240)));
      t.decide({
        key: replyKey,
        title: titleFor("Post the reply on " + what(d.number), item),
        // What Post does, then the words the person decides on: the reply's first sentence. The rest is the view and the body.
        summary: clip((dry ? "Dry run: Post only records the reply." : "Post adds the reply as your comment on GitHub.") + " It opens: \u201c" + clipWords(firstSentence(d.text), 130) + "\u201d", 280),
        body: clipBlock(d.text, 4000),
        options: [
          { intent: "post", label: "Post the reply", detail: "Posts the draft as your comment on GitHub.", confirm: "Tap again: post" },
          { intent: "edit", label: "Ask for an edit", detail: "Say what to change; the drafting agent writes a new version." },
          { intent: "hold", label: "Hold for 24 h", detail: "Asks again after 24 h." },
        ],
        ...advise(item),
        text: "optional",
        priority: "today",
        links: [{ label: clip(what(d.number) + " on GitHub", 40), href: item.url }],
        view,
        ...withReply,
      });
    }
    // A merge: a green PR with an approving verdict beside the draft.
    if (item.kind !== "pr" || d.verdict === null || !/^approve\b/i.test(d.verdict)) continue;
    const mergeKey = "merge-" + d.number;
    if (item.ci !== "green") lines.push("No merge offered for PR " + d.number + ": CI is " + item.ci + ".");
    else if (merged.has(d.number)) done.push({ text: "Merge of PR " + d.number, end: "would merge", detail: "Dry run: nothing was merged. Merge has no live path yet, the tap is only recorded." });
    else if (t.isClosed(mergeKey) === null) {
      shown[mergeKey] = mergeHash(d);
      t.decide({
        key: mergeKey,
        title: titleFor("Merge PR " + d.number, item),
        // Merge has no live path: with live on, the summary says what a tap does instead of the dry-run words.
        // The second sentence is the fact that decides it; the verdict's own words are the body.
        summary: (dry ? "Dry run: nothing is merged." : "A tap is recorded for you, merge has no live path yet.") + " The verdict approves it, and CI is green.",
        body: clipBlock("Verdict:\n" + d.verdict + "\n\nCI: green. Opened " + opened + " ago.", 4000),
        options: [
          { intent: "merge", label: "Merge the PR", detail: "Merges the PR into its base branch.", confirm: "Tap again: merge" },
          { intent: "not-yet", label: "Hold for 24 h", detail: "Asks again after 24 h." },
        ],
        text: "none",
        priority: "today",
        links: [{ label: clip("PR " + d.number + " on GitHub", 40), href: item.url }],
        ...withReply,
      });
    }
  }
  t.decisions.splice(20);
  t.state.set("offered", Object.fromEntries(t.decisions.map((d) => [d.key, shown[d.key] ?? ""])));
  const offeredCount = t.decisions.filter((d) => d.key.startsWith("reply-")).length;

  // ── The places and the Session ──
  t.put(show, { label: "PRs", icon: "chat", badge: offeredCount, word: offeredCount > 0 ? "prs " + offeredCount : null, tone: "accent" });
  const hasDraft = new Set(drafts.filter((d) => !answered.has(d.number)).map((d) => d.number));
  const row = (i: Item): Node => {
    const end = answered.has(i.number) ? "answered" : i.kind === "pr" ? (i.draft ? "draft" : i.ci) + ", " + age(now - Date.parse(i.createdAt)) : age(now - Date.parse(i.createdAt));
    return v.row(clip("#" + i.number + " " + i.title, 120), { end: clip(end, 24), href: i.url, ...(i.ci === "red" ? { tone: "danger" as const } : {}), ...(hasDraft.has(i.number) ? { badge: "" } : {}) });
  };
  const groupOf = (label: string, list: Item[]): Node => {
    const ordered = [...list.filter((i) => hasDraft.has(i.number)), ...list.filter((i) => !hasDraft.has(i.number))];
    const kids = ordered.slice(0, 23).map(row);
    return v.group(list.length > 23 ? [...kids, v.para("and " + (list.length - 23) + " more on GitHub")] : kids, { label, badge: list.length });
  };
  const prs = items.filter((i) => i.kind === "pr");
  const issues = items.filter((i) => i.kind === "issue");
  const view: Node[] = [v.number(offeredCount, { label: offeredCount === 1 ? "draft to post" : "drafts to post", tone: offeredCount > 0 ? "accent" : "ok" }), ...notes.map((n) => v.line(clip(n, 240), { role: "status" }))];
  const readProblem = open.error === null ? null : open.stale ? open.error + ", showing the read of " + age(now - open.at) + " ago" : open.error;
  const problem = readProblem ?? (gh === null ? noGh : null);
  if (problem !== null) view.push(v.card([v.para(clip(problem, 400))], { tone: "warn" }));
  if (!existsSync(draftsDir)) view.push(v.line(clip("No drafts folder at " + draftsDir, 240), { role: "note" }));
  const nowhere = "No session is named " + replySession + ": an edit's words reach no agent, and every answer is recorded in this trick's state folder.";
  if (replyTo === null && t.decisions.length > 0) view.push(v.list([v.row("answers are recorded here only", { tone: "muted" }, [v.para(clip(nowhere, 400))])]));
  view.push(...cards.slice(0, 8));
  if (done.length > 0) view.push(v.group(done.slice(0, 23).map((r) => v.row(clip(r.text, 120), { end: clip(r.end, 24), tone: "muted", ...(r.href ? { href: r.href } : {}) }, [v.para(clip(r.detail, 400))])), { label: "Records", badge: done.length }));
  for (const l of lines.slice(0, 6)) view.push(v.line(clip(l, 240), { role: "note" }));
  if (prs.length > 0) view.push(groupOf("Pull requests", prs));
  if (issues.length > 0) view.push(groupOf("Issues", issues));
  if (items.length === 0 && problem === null) view.push(v.para("Nothing open."));
  const red = prs.filter((p) => p.ci === "red").length;
  const subtitle = prs.length + " PRs open, " + red + " red, " + issues.length + " issues; " + offeredCount + " " + (offeredCount === 1 ? "reply" : "replies") + " to post";
  t.session({ subtitle: clip(subtitle, 120), ...(offeredCount > 0 ? { badge: { count: offeredCount } } : {}), view });
  t.asOf(open.at);
  t.fresh("15m");
});
