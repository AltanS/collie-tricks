# Release Gates, the release gate

**What this assumes.** Release Gates was written for one release process and has not been rewritten for others. It is off until
you set `version` in `config.toml`. It reads seven gates, and four of them expect the owner's files:

- Gate 1 (CI) is generic: the newest run of `workflow` on `branch` in `repo`, read with `gh`.
- Gate 5 (changelog) expects a Keep a Changelog file: `## [Unreleased]` empty, `## [<version>]` on top.
- Gates 2 and 3 read result files in two fixed formats (`leg_results`, `leg_logs`). Gate 4 reads a rehearsal file whose last
  line is `rollback: ok`. Gate 7 reads a note that names the version. Gate 6 reads a hold file.
- A gate with an empty or missing path reads "no report" and is never green, so the Decision is asked only when all seven
  are green. To adapt Release Gates, change the paths in `config.toml` and the gate functions in `program.ts`.
- The trick never tags and never pushes. A yes is a record, and the release session does the tag.

Seven gates, each read on this machine. When all seven are green, one Decision: "Tag and push v<version>?". The trick
never tags: a yes is a dated record with the rid in `tag-yes.jsonl`. The release session gets the answer
through the Decision's `replyTo` and does the tag. `SKILL.md` is its half (`collie trick skill release-gates`).

- Files: `trick.toml` (`run = "program.ts"`, every 5 min, `env = ["DBUS_SESSION_BUS_ADDRESS"]` for gh's
  keyring login), `program.ts`, `trick.ts` (Collie's helper v3, unmodified: the records, the cache,
  the mask, the `show` setting), `config.toml`, `test.sh`, `fixtures/`.
- `config.toml`: `repo`, `version` (empty: one muted row "no release open", no count, no Decision), `branch`,
  `workflow`, `minor`, `checkout`, `leg_results`, `leg_logs`, `rehearsal`, `hold`, `counsel`, `release_session`, `show`
  (where the count shows; default `["tabbar"]`; an unknown word is a warn row).
- Gates: 1 CI on the branch (`gh run list`, cached 60 s; a red run adds its failed jobs from `gh run view`),
  2 the newest browser leg `table.md`, 3 the newest `leg-core-*.txt`, 4 the Windows rehearsal (skipped when
  `minor = false`), 5 `CHANGELOG.md` on the branch (`git show`: Unreleased empty, the version on top, not
  tagged yet), 6 no hold file, 7 a counsel note that names the version and is newer than the newest tag. A
  gate that cannot be read, or whose report is older than the newest tag, is idle with "no report".
- On the phone, while a release is open: an item "Gates" in the Dashboard's bottom bar with the badge
  `<green>/7`, and the Session: the number, the first red gate on top with its masked log tail in a code
  block, the seven numbered chips, and one row per gate with its detail. `status` and `belt` show
  `gates <green>/7`.
- The Decision: a view with the seven numbered chips, one row per gate with its proof at the end (the CI row
  opens the run on GitHub, and the card shows the host); the gate table as the body; options "Tag and push" (two taps, a confirm of at most 24
  characters) and "Hold for 24 h" (`not-yet`, closed 24 h); `recommends` tag, why "All seven gates are green." (the Decision exists only then; advice only, it never arms the confirm); `text` none; priority now; `about` and `replyTo`
  the session whose exact NAME is `release_session`. With none, the Session shows one muted row, "answers are
  recorded here only". The summary: "Your yes goes to the release session, which tags and pushes v<version>. All seven gates are green."
- Records keep `seen`. A tag tap while a gate is red records nothing. A `dismiss` writes
  `tag-dismissed.jsonl` and closes the key for 24 h. A yes ends the key for that version.
- Only read verbs run (`gh run list`, `gh run view`, `git for-each-ref`, `git show`); any other verb throws
  before it runs. `TRICK_FIXTURE=all-green` forces every gate green, for the tests only.
- State folder: `tag-yes.jsonl`, `tag-dismissed.jsonl`, `closed.json`, `cache-ci.json`.
- Check: `COLLIE_REPO=/path/to/collie sh test.sh` (a Collie source checkout with trick support; "all ok").
