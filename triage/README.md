# Triage, public replies on the operator's own login

Triage assumes a workflow: a triage agent writes reply drafts as files, and you decide on your phone whether each one is posted
under your own GitHub login. It is safe by default: `live = false` in `config.toml` makes a Post tap write a record and
nothing else. Set `repo` and `drafts` to your own. The house check in `lib.ts` is one house style (first person, no
praise words, no date promises, no em dash, one paragraph, no exclamation mark); read it and change it to suit you.

Triage reads the open PRs and issues of `repo` with gh, read only, and offers each draft in `drafts` that
passes the house check as a Decision. `SKILL.md` is the triage agent's half (`collie trick skill triage`).

- Files: `trick.toml` (`run = "program.ts"`, every 5 min, `env = ["DBUS_SESSION_BUS_ADDRESS"]` because gh
  reads its login from the keyring over the session bus), `program.ts`, `lib.ts` (the house check only),
  `trick.ts` (Collie's helper v3, unmodified: the records, the cache, the mask, the `show` setting), `config.toml`, `test.sh`, `fixtures/`.
- `config.toml`: `repo`, `drafts` (a folder of `<n>.md` and `<n>.verdict`), `live` (false: a Post tap only
  records), `reply_session` (the session whose exact NAME gets `replyTo`), `names` (the names the check
  refuses; empty: the words of `git config --global user.name`), `show` (where the count shows; default
  `["dashboard"]`; an unknown word is a warn row).
- On the phone: a Dashboard tile "Triage" with the number of drafts offered, and the Session: the number,
  what a tap did, a red card per refused draft with its failing line, the records (would post, posted, would
  merge), and the open PRs and issues. `status` and `belt` show `triage <n>` only while n > 0.
- Reads, cached 60 s in the state folder, a tap run always from the cache: `gh pr list`, `gh issue list`,
  `gh api -X GET user` (24 h), `gh api -X GET repos/<repo>/issues/<n>/comments` per draft. A failed read serves
  the cached copy with its age. Any other gh verb throws before it runs, except the live comment.
- `reply-<n>`: "Post the reply on PR <n> (<its title>)?", at most 60 characters (the PR's title without its
  `fix(...):` prefix, cut at a word with "…"); the summary says what Post does, then "It opens: “<the draft's
  first sentence>”"; options Post the reply (two taps, "Tap again: post"), Ask for an edit (words), Hold for 24 h; `text`
  optional; `recommends` from facts the run read, advice only, never pre-selected: Post ("The house check passes and CI is green.") for a PR with green CI, Post ("The house check passes.") for an issue, Hold ("CI is red on this pull request." or "CI still runs.") for a PR with red or pending CI, nothing for a PR with no CI. The draft passed the house check, or it would not be a Decision. The view: the house check as a bar of
  chips, the CI state and age, the thread's last comment, and the first 240 characters of the draft. The whole
  draft is the body, behind More. `merge-<n>`: "Merge PR <n> (<its title>)?", the summary "The verdict approves
  it, and CI is green." after the dry-run or no-live-path words, the verdict in the body, options Merge the PR
  ("Tap again: merge") and Hold for 24 h (`not-yet`), `text` none, for a green PR with an `approve` verdict.
- Dry run (`live = false`): the summary starts "Dry run: Post only records the reply." (a
  merge: "Dry run: nothing is merged."), and a Post writes a `would` record in `posts.jsonl` and nothing else.
  No gh write runs; `test.sh` checks it on every answer. With `live = true` a Post runs `gh pr comment <n>
  --body-file` (or `gh issue comment`) once per rid: a `started` record first, then `posted` with the URL, or
  `failed`. A post only goes out for the draft the Decision showed (`offered.json`). Merge never runs.
- Edit keeps the words in `edits.jsonl` and `edit-<n>.json` in the state folder; they reach the triage agent
  through `replyTo`, and the Session shows them until a new draft arrives. Hold for 24 h (both) and a dismiss close
  the key for 24 h; a dismiss writes `dismissed.jsonl`. Every record keeps `seen`.
- No session of that name: the Session shows one muted row, "answers are recorded here only".
- State folder: `posts.jsonl`, `would-merge.jsonl`, `dismissed.jsonl`, `edits.jsonl`, `edit-<n>.json`,
  `closed.json`, `offered.json`, `cache-*.json`. The program writes nowhere else.
- Check: `COLLIE_REPO=/path/to/collie sh test.sh` (a Collie source checkout with trick support; fake gh, fake git, "all ok").
