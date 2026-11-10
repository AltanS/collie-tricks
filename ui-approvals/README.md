# UI Approvals, the yes by name for UI changes

UI Approvals assumes a workflow: a worker (a person or an agent) keeps a `LOOK.md` and a `.look/` folder of shots at the root of a
branch worktree, and you answer yes, no or change by name before a visible change ships. It is off until you set `roots`
in `config.toml`.

UI Approvals asks one Decision per visible change that a worker lists in `LOOK.md`, with its shot. `SKILL.md` is the
worker's half (`collie trick skill ui-approvals` prints it while the trick is on). The notes file a worker writes is still called `LOOK.md`, and its shots folder `.look/`. Agents already write these two names, so they stay.

- Files: `trick.toml` (`run = "program.ts"`, every 5 min), `program.ts`, `trick.ts` (Collie's helper v3,
  unmodified: the records, the cache, the mask, the `show` setting), `config.toml`, `test.sh`, `fixtures/`.
- `config.toml`: `roots` (globs, `~/...` allowed; every match with a `LOOK.md` is a branch root), `lane` (the
  link base for a route that is a path; empty: no link), `reply_session` (see below; empty: none), `show` (where the count shows: any of
  `"dashboard"`, `"tabbar"`, `"status"`, `"belt"`; default `["dashboard"]`; an unknown word is a warn row).
- On the phone: a Dashboard tile "Approvals" with the number of changes waiting (no badge at 0), and the Session:
  the number, Waiting (name, age of the shot, branch), Given (the audit, newest first, at most 20), the
  dismissed keys, and Not asked (a warn row per refused line: no shot, a shot over 2 MB or over 512 KB, a
  LOOK.md or `.look/` that git would commit, git missing). `status` and `belt` show `approvals <n>` only while n > 0.
- A Decision: key `<branch>-<name>`, title `Ship “<name>”?` (the name cut to 50 characters), the sentence as the summary, the shot and the
  before shot as media ("After", "Before"), a view with the two shots as a before and after compare
  (`v.beforeAfter(1, 0)`, only when there is a before shot) and Where, Branch and Session rows; when the
  route is a path, the Where row opens `<lane><route>` and the card shows the lane's host, options Ship it (`yes`), Keep the old look (`no`) and Ask for a change (`change`), each with a detail line, `recommends` only when the line carries a suggest field (below), priority today, `text`
  optional. `replyTo`: the session whose folder is the root, else the session NAMED `reply_session` (exact
  match), else none; then the Session shows one muted row, "answers are recorded here only".
- The suggest field: a LOOK.md line may end with `| suggest yes|no|change: <why>` (after the shot, or after the
  before shot; the reason is 1 to 200 characters). The trick has no opinion of its own and never fakes one: the
  Decision carries `recommends: { intent, why }` only for a field in this strict form, and the why names the worker,
  because the card says "Recommended" and the trick must not take the credit. `why` is "From <session name>: <reason>"
  when a session's folder is the root and it has a name, else "From the branch's worker: <reason>" (the
  `reply_session` is not known to be the worker, so it is not named). A field that starts with `suggest` and is
  not in the strict form (another answer, no colon, no reason, a reason over 200 characters, capital letters) is
  ignored: the change is still asked, with no recommendation, and the Session shows one warn row per such line,
  "suggest field not understood" (group "Suggest field"). The field is part of the line, so a changed suggest
  changes the hash: the Decision is new content, and an earlier answer does not hold for it.
- The branch comes from `git branch --show-current`; `check-ignore` and `status --porcelain` say whether
  LOOK.md or `.look/` would be committed. Each root's git reads are cached 60 s in the state folder
  (`t.cached`); a tap run uses the kept copy at any age.
- The hill takes images from the trick folder only, so UI Approvals copies each shot to `media/<key>-<hash>` and
  removes copies no Decision names. `media/` is outside the code hash.
- An answer appends one line to `given.jsonl` (date, answer, words, rid, the `hash` of the line and the shots
  that were shown, and `seen`, the hill's hash of the version the person saw). A repeated rid writes nothing.
  `offered.json` holds the hash each key showed; an answer counts for that hash only, so a changed line or
  shot is asked again. A `dismiss` writes `dismissed.jsonl` and closes the key for 24 h.
- State folder: `given.jsonl`, `dismissed.jsonl`, `offered.json`, `closed.json`, `cache-git-*.json`.
- Check: `sh test.sh` ("all ok"). It needs a Collie source checkout with trick support: `COLLIE_REPO=/path/to/collie sh test.sh`. It runs
  `collie trick check --run` and `collie trick dev --json` from that source with throwaway state and config folders, and the
  program with a fake git.
