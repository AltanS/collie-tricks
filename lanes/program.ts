// The Lanes trick: which commit a running Collie (a "lane") serves, beside the head of each checkout. Read only.
// The lane is read from its standby door (`health_url` in config.toml): plain HTTP, GET only, no login. Its version
// header ends "+<sha>". With no `health_url` the lane is not read and only the checkout heads show.
import { run, v } from "./trick.ts";

run(async (t) => {
  const home = process.env.HOME ?? "~";
  const list = (value: unknown, fallback: string[]) => (Array.isArray(value) ? value.map(String) : fallback);
  const text = (value: unknown, fallback: string) => (typeof value === "string" ? value : fallback);
  const health = text(t.config.health_url, "");
  const label = text(t.config.label, "Lane").slice(0, 60) || "Lane";
  const show = t.show(["dashboard"]);
  const git = t.tool("git");
  const heads = await Promise.all(
    list(t.config.checkouts, []).map(async (path) => {
      const dir = t.path(path);
      const [sha, subject] = await Promise.all([t.sh(git, ["-C", dir, "rev-parse", "--short", "HEAD"]), t.sh(git, ["-C", dir, "log", "-1", "--format=%s"])]);
      return { name: dir.replace(home, "~"), sha: sha.ok ? sha.stdout.trim() : "", subject: subject.ok ? subject.stdout.trim() : "not a git checkout" };
    }),
  );
  const lane = health === ""
    ? null
    : await fetch(health, { signal: AbortSignal.timeout(2000) })
        .then(async (r) => ({ version: r.headers.get("x-collie-version") ?? "", state: String(((await r.json()) as { state?: unknown }).state ?? "") }))
        .catch(() => null);
  const served = lane?.version.split("+")[1]?.slice(0, 9) ?? "";
  const head = heads[0]?.sha ?? "";
  const stale = served !== "" && head !== "" && !served.startsWith(head) && !head.startsWith(served);
  const sha = served || head || "none";
  const warn = stale ? ("warn" as const) : undefined;

  t.put(show, { label: "Lanes", icon: "branch", badge: sha, word: sha.slice(0, 12), tone: warn, itemTone: warn });
  const laneRow = v.row(label, { end: served || lane?.state || "no answer", icon: "machine", ...(stale ? { tone: "warn" as const } : {}) }, [
    v.para(lane === null ? "The standby door gave no answer in 2 s." : stale ? `Serves ${served}, but ${heads[0]?.name} is at ${head}: rebuild the lane.` : `Version ${lane.version || "unknown"}, ${lane.state}.`),
  ]);
  const rows = heads.map((h) => v.row(h.name.slice(0, 120), { end: h.sha || "no head", icon: "branch", cut: "mid" }, [v.para(h.subject.slice(0, 400) || "no subject")]));
  const shown = health === "" ? rows : [laneRow, ...rows];
  t.session({ subtitle: stale ? `serves ${served}, checkout at ${head}` : `serves ${sha}`, view: shown.length === 0 ? [v.para("Set checkouts or health_url in config.toml.")] : [v.list(shown)] });
  t.fresh("10m");
});
