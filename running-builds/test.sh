#!/bin/sh
# Checks the Running Builds trick on a copy of this folder: two throwaway git checkouts, a throwaway standby door (a small
# Bun server on a free loopback port), the program run as the bridge runs it, `collie trick check` and
# `collie trick dev` from a Collie source checkout (COLLIE_REPO, with trick support). It touches no real checkout and no
# real lane, and writes nothing in the trick folder. Ends with "all ok". Writes go to /dev/null or through tee only.
here=$(cd "$(dirname "$0")" && pwd)
repo=${COLLIE_REPO:-}
BUN=$(command -v bun) || { echo "no bun on PATH" >&2; exit 2; }
[ -f "$repo/web/src/lib/tricks/schema.ts" ] || { echo "set COLLIE_REPO to a Collie source checkout that has trick support (cli/main.ts and web/src/lib/tricks/schema.ts)" >&2; exit 2; }
tmp=$(mktemp -d)
pids=""
trap 'for p in $pids; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"' EXIT
failed=0
pass() { echo "ok   $1"; }
miss() { echo "FAIL $1"; failed=1; }

cp -r "$here" "$tmp/running-builds"
work=$tmp/running-builds
for c in one two; do
  git init -q "$tmp/$c" && git -C "$tmp/$c" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "the $c fixture commit"
done
one=$(git -C "$tmp/one" rev-parse --short HEAD)
two=$(git -C "$tmp/two" rev-parse --short HEAD)
full=$(git -C "$tmp/one" rev-parse HEAD)
served=$(printf '%s' "$full" | cut -c1-9)

# door NAME SHA: a standby door on a free loopback port, answering a version that ends in +SHA.
door() {
  SHA=$2 "$BUN" -e 'const s = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => Response.json({ state: "standby" }, { headers: { "x-collie-version": "1.0.0+" + process.env.SHA } }) }); console.log(s.port); setInterval(() => {}, 1e6);' > "$tmp/door.$1" &
  pids="$pids $!"
  n=0; while [ ! -s "$tmp/door.$1" ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
  [ -s "$tmp/door.$1" ] || { echo "the test door did not start" >&2; exit 2; }
}
door same "$full"
door other deadbeef0123456
same=http://127.0.0.1:$(head -1 "$tmp/door.same")/standby/health
other=http://127.0.0.1:$(head -1 "$tmp/door.other")/standby/health
closed=http://127.0.0.1:9/standby/health

# config CHECKOUTS HEALTH SHOW
config() { printf 'checkouts = [%s]\nhealth_url = "%s"\nlabel = "Lane"\nshow = [%s]\n' "$1" "$2" "$3" | tee "$work/config.toml" >/dev/null; }
all="\"$tmp/one\", \"$tmp/two\", \"$tmp/none\""
facts='{"contract":1,"trigger":{"kind":"timer"},"trick":{"id":"running-builds","dir":"'$work'","state":"'$tmp/state'"},"memberId":"laptop","host":"laptop","sessions":[],"spaces":[]}'
was=$(cd "$work" && find . -type f ! -name config.toml | sort | xargs md5sum)
runit() { printf '%s' "$facts" | (cd "$work" && "$BUN" ./program.ts) 2>/dev/null; }

# check NAME MODE: the document of the current config must hold what MODE says.
# same: the lane serves the head of the first checkout. other: another commit, a warn row. closed: no answer, the tile shows the first head.
check() {
  TRICK_SCHEMA=$repo/web/src/lib/tricks/schema.ts "$BUN" -e '
const { parseTrickDocumentText } = await import(process.env.TRICK_SCHEMA);
const [text, mode, one, two, served] = process.argv.slice(1);
const p = parseTrickDocumentText(text, { declared: ["dashboard", "status", "session"] });
const doc = JSON.parse(text);
const at = doc.parts.map((x) => x.at).join(",");
const rows = doc.parts.find((x) => x.at === "session").view[0].kids;
const lane = rows[0];
const badge = doc.parts[0].item.badge;
const heads = rows.slice(1);
const common = p.refusals.length === 0 && at === "dashboard,status,session" && JSON.stringify(doc.decisions) === "[]"
  && lane.text === "Lane" && heads[0].attrs.end === one && heads[0].kids[0].text === "the one fixture commit" && heads[1].attrs.end === two
  && heads[2].attrs.end === "no head" && heads[2].kids[0].text === "not a git checkout";
const byMode = {
  same: lane.attrs.end === served && lane.attrs.tone === undefined && badge === served && doc.parts[1].chip.text === served,
  other: lane.attrs.end === "deadbeef0" && lane.attrs.tone === "warn" && lane.kids[0].text.includes("rebuild the lane") && badge === "deadbeef0",
  closed: lane.attrs.end === "no answer" && lane.kids[0].text.includes("no answer in 2 s") && badge === one,
};
if (!(common && byMode[mode])) { console.error(text); process.exit(1); }
' "$out" "$1" "$one" "$two" "$served" && pass "$2" || miss "$2"
}

config "$all" "$same" '"dashboard", "status"'
start=$(date +%s)
out=$(runit) || miss "the program exited non-zero"
[ $(($(date +%s) - start)) -le 4 ] && pass "one run takes at most 4 s (the door's timeout is 2 s)" || miss "the run took too long"
check same "the door serves the head: a tile, a chip, the lane row, one row per checkout, no Decisions"
printf '%s' "$out" | grep -q '"decisions":\[\]' && pass "decisions: an empty list, nothing posted" || miss "decisions"

config "$all" "$other" '"dashboard", "status"'
out=$(runit); check other "the door serves another commit: a warn row that says rebuild"
config "$all" "$closed" '"dashboard", "status"'
out=$(runit); check closed "no answer from the door: the tile shows the first head"

config "\"$tmp/one\"" "" '"dashboard"'
out=$(runit)
printf '%s' "$out" | grep -q '"at":"dashboard"' && ! printf '%s' "$out" | grep -q '"at":"status"' && pass "no show key: the tile only, no chip" || miss "the default show"
printf '%s' "$out" | grep -q '"text":"Lane"' && miss "no health_url: the lane row must not show" || pass "no health_url: no lane row, the heads only"
config "" "" '"dashboard"'
out=$(runit)
printf '%s' "$out" | grep -q 'Set checkouts or health_url in config.toml' && pass "nothing configured: one plain line" || miss "nothing configured: $out"
config "\"$tmp/one\"" "" '"dashboard", "belt"'
out=$(runit)
printf '%s' "$out" | grep -q 'show names \\"belt\\", which this trick ignores: use dashboard, status' && pass "a place trick.toml does not list: one warn row" || miss "show belt: $out"

config "\"$tmp/one\"" "$same" '"dashboard"'
cli() { (cd "$repo" && env PATH="$PATH" HOME="$HOME" COLLIE_STATE_DIR="$tmp/cli-state" HERDR_PLUGIN_CONFIG_DIR="$tmp/cli-config" "$BUN" cli/main.ts "$@" 2>&1); }
check=$(cli trick check --run "$work")
printf '%s\n' "$check" | grep -q '^ok: no problems.' && pass "trick check --run: no refusal" || { miss "trick check --run"; printf '%s\n' "$check"; }
kinds=$(printf '%s\n' "$check" | sed -n 's/^  warn: \([a-z.]*\):[0-9]* \([a-z]*\).*/\1 \2/p' | sort -u | tr '\n' ',')
[ "$kinds" = "program.ts reaches,program.ts starts," ] && pass "the only warnings: the fetch and the git reads (test.sh and the shipped helper are not grepped)" || miss "warnings: $kinds"
printf '%s\n' "$check" | grep -q '^  helper: trick.ts is collie trick helper v3' && pass "trick check names the shipped helper v3" || miss "trick check: no helper line"
dev=$(cli trick dev "$work" --json)
printf '%s' "$dev" | "$BUN" -e 'const d = JSON.parse(await Bun.stdin.text()); process.exit(d.outcome === "exited" && d.refusals.length === 0 && d.decisionsListed && d.decisions.length === 0 && d.parts.map((p) => p.place).join() === "dashboard,session" ? 0 : 1)' && pass "trick dev --json: the tile and the Session, no Decisions" || miss "trick dev --json"

[ "$(cd "$work" && find . -type f ! -name config.toml | sort | xargs md5sum)" = "$(printf '%s\n' "$was" | grep -v ' ./config.toml$')" ] && pass "the trick folder is unchanged" || miss "the program wrote into its own folder"
[ ! -e "$tmp/state" ] && pass "nothing in the state folder" || miss "the program wrote state"

[ "$failed" = 0 ] && echo "all ok" || { echo "FAILED"; exit 1; }
