# Running Builds, which commit a running Collie serves

The smallest useful trick: `program.ts` (about 40 lines) and Collie's helper `trick.ts` (v4), unmodified. It shows which
commit a running Collie (a "lane") serves, beside the head of each checkout in `config.toml`. A lane is one running
Collie built from one checkout, such as a dev copy next to a release copy. It does nothing until you set `checkouts`
or `health_url`.

- Reads only: `git -C <checkout> rev-parse --short HEAD` and `git -C <checkout> log -1 --format=%s` per
  checkout, and one `GET <health_url>` with a 2 s timeout. The URL is the standby door of a Collie bridge: plain HTTP,
  GET only, no login, and its `x-collie-version` header ends in `+<sha>` of the build it runs. Any failure reads as
  "no answer". With no `health_url` the lane is not read at all.
- `config.toml`: `checkouts` (the first is the one the lane builds from), `health_url`, `label` (the name of the lane
  row), `show`.
- On the phone: a Dashboard tile "Builds" with the served commit as its badge (the first checkout's head when
  the door gives no answer), in the warn tone when the lane serves another commit than that head. The
  Session: one row for the lane (when `health_url` is set), one row per checkout (path, short sha, subject).
  `show = ["dashboard", "status"]` adds a status chip with the sha; any other word is ignored with one warn row (`t.show`).
- No Decisions: every run prints `"decisions": []`. No state, no files written. Every 5 minutes.
- `collie trick check` warns about the one HTTP read (network) and the two git reads (spawn), both true. It
  lists `trick.ts` as helper v4 and does not grep it, nor `test.sh` and this README.
- Check: `COLLIE_REPO=/path/to/collie sh test.sh` ("all ok"). A Collie source checkout with trick support is needed. The test
  starts its own throwaway door on a free loopback port, so it never reads a real lane.
