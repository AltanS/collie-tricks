#!/bin/sh
# Checks the Release Gates trick on a copy of this folder, with no network: a fake gh and a fake git on PATH serve fixture
# CI runs, tags and changelogs, and log every call. The trick must never run a tag, a push or a release.
# Ends with "all ok". Needs sh, bun, and a Collie source checkout with trick support (COLLIE_REPO),
# whose CLI runs `trick check` and `trick dev` from source with throwaway state and config folders.
here=$(cd "$(dirname "$0")" && pwd)
repo=${COLLIE_REPO:-}
schema=$repo/web/src/lib/tricks/schema.ts
[ -f "$schema" ] || { echo "set COLLIE_REPO to a Collie source checkout that has trick support (cli/main.ts and web/src/lib/tricks/schema.ts); no schema at $schema" >&2; exit 2; }
BUN=$(command -v bun) || { echo "no bun on PATH" >&2; exit 2; }
BUNDIR=$(dirname "$BUN")
PLACES=dashboard,tabbar,status,belt,session
unset TRICK_FIXTURE

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -r "$here" "$tmp/release-gates"
work=$tmp/release-gates
fix=$work/fixtures
rel=$tmp/release
sed "s#SCHEMA#$schema#" "$fix/assert.ts.in" > "$tmp/assert.ts"
mkdir "$tmp/bin" "$tmp/state" "$rel" "$tmp/checkout"

cat > "$tmp/bin/gh" <<EOF
#!/bin/sh
echo "gh \$*" >> "$tmp/gh.log"
case "\$1 \$2" in
  "run list") cat "$fix/gh/run-\${FAKE_CI:-success}.json" ;;
  "run view") cat "$fix/gh/run-view-\$3.json" ;;
  *) echo "WRITE \$*" >> "$tmp/gh.log"; exit 1 ;;
esac
EOF
# The fake git: tags newest first (v2.3.4 on 2026-11-08 00:00 UTC), and CHANGELOG.md on the branch.
cat > "$tmp/bin/git" <<EOF
#!/bin/sh
echo "git \$*" >> "$tmp/git.log"
[ "\$1" = "-C" ] && shift 2
case "\$1" in
  for-each-ref) [ -n "\${FAKE_TAGGED:-}" ] && echo "v\$FAKE_TAGGED 1794226000"; echo "v2.3.4 1794096000" ;;
  show) [ "\$2" = "main:CHANGELOG.md" ] && cat "$fix/changelog/\${FAKE_CHANGELOG:-released}/CHANGELOG.md" ;;
  *) echo "WRITE \$*" >> "$tmp/git.log"; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/git"
: > "$tmp/gh.log"; : > "$tmp/git.log"

# config VERSION MINOR RESULTS LOGS REHEARSAL [EXTRA LINE]
config() {
  printf 'repo = "example/repo"\nversion = "%s"\nbranch = "main"\nminor = %s\ncheckout = "%s"\nleg_results = "%s"\nleg_logs = "%s"\nrehearsal = "%s"\nhold = "%s"\ncounsel = "%s"\nrelease_session = "release"\n%b' \
    "$1" "$2" "$tmp/checkout" "$fix/$3" "$fix/$4" "$5" "$rel/hold" "$rel/counsel.md" "${6:-}" > "${DIR:-$work}/config.toml"
}
fresh() {
  rm -rf "$tmp/state" "$rel"; mkdir "$tmp/state" "$rel"
  echo "counsel v2.4.0-rc.1: no blocker" > "$rel/counsel.md"; touch -d "2026-11-09 10:00 UTC" "$rel/counsel.md"
}
touch -d "2026-11-09 11:00 UTC" "$fix/logs/leg-core-2.4.0.txt" "$fix/logs-red/leg-core-2.4.0.txt"
V=2.4.0-rc.1
K=tag-2-4-0-rc-1

failed=0
pass() { echo "ok   $1"; }
miss() { echo "FAIL $1"; failed=1; }
NOW=1794227400
facts() {
  printf '{"contract":1,"trigger":%s,"trick":{"id":"release-gates","dir":"%s","state":"%s"},"memberId":"laptop","host":"laptop","sessions":%s,"spaces":[]}' "$1" "${DIR:-$work}" "${STATE:-$tmp/state}" "${SESSIONS:-[]}"
}
# step NAME TRIGGER_JSON EXPECT_JSON [ENV...]. A fixed clock: 2026-11-09 12:30 UTC.
step() {
  name=$1 trig=$2 want=$3
  shift 3
  out=$(facts "$trig" | (cd "${DIR:-$work}" && env PATH="$tmp/bin:$BUNDIR:/usr/bin:/bin" TRICK_TOOLS_ONLY_PATH=1 TRICK_NOW=$NOW "$@" "$BUN" ./program.ts) 2>"$tmp/stderr") || { miss "$name: exited non-zero"; cat "$tmp/stderr"; return; }
  if printf '%s' "$out" | "$BUN" "$tmp/assert.ts" "$want" $PLACES; then pass "$name"; else miss "$name"; fi
}
calls() { wc -l < "$tmp/gh.log" | tr -d ' '; }
cli() { (cd "$repo" && env PATH="$tmp/bin:$BUNDIR:/usr/bin:/bin" HOME="$HOME" COLLIE_STATE_DIR="$tmp/cli-state" HERDR_PLUGIN_CONFIG_DIR="$tmp/cli-config" "$BUN" cli/main.ts "$@"); }
timer='{"kind":"timer"}'

config "$V" true results logs "$fix/rehearsal-ok.txt"; fresh

# ── The platform's own checks ──
if cli trick check --run "$work" > "$tmp/check.txt" 2>&1 && grep -qE '^ok: (no problems|it runs on this machine, but it cannot be proposed)\.' "$tmp/check.txt"; then pass "trick check --run: no refusal"; else miss "trick check --run"; cat "$tmp/check.txt"; fi
cli trick dev "$work" --json > "$tmp/dev.json" 2>&1
if "$BUN" -e '
const d = JSON.parse(await Bun.file(process.argv[1]).text());
const at = d.parts.map((p) => p.part.at + ":" + p.part.id).join(",");
const k = d.decisions[0];
const flat = JSON.stringify(k?.view ?? []);
const ok = d.outcome === "exited" && d.refusals.length === 0 && at === "tabbar:tabbar,session:main" && d.parts[0].part.item.badge === "7/7" && d.decisions.length === 1 && k.key === process.argv[2]
  && k.options.map((o) => o.intent + (o.confirm ? "!" : "")).join() === "tag!,not-yet" && flat.includes("012345678 success") && flat.includes("https://github.com/example/repo/actions/runs/101");
if (!ok) { console.error(JSON.stringify({ at, outcome: d.outcome, problem: d.problem, refusals: d.refusals, flat })); process.exit(1); }' "$tmp/dev.json" "$K"; then pass "trick dev --json: Gates 7/7 in the bar, the Session, the Decision with its proof"; else miss "trick dev --json"; fi
cli trick dev "$work" --json --tap tag --node "hill/$K" > "$tmp/devtap.json" 2>&1
grep -q "Yes for v$V recorded." "$tmp/devtap.json" && grep -q '"decisions": \[\]' "$tmp/devtap.json" && pass "trick dev --tap tag --node hill/$K: a yes record, no Decision" || miss "trick dev --tap tag"
# One request id, a kept state folder: the same tag tap twice is one yes record, and the trick still never tags.
RID=7e8f9a0b-1c2d-4e3f-8a4b-5c6d7e8f9a0b
cli trick dev "$work" --json --tap tag --node "hill/$K" --rid $RID --state "$tmp/devstate" > /dev/null 2>&1
cli trick dev "$work" --json --tap tag --node "hill/$K" --rid $RID --state "$tmp/devstate" > "$tmp/devtap2.json" 2>&1
grep -q 'This tap was recorded already.' "$tmp/devtap2.json" && [ "$(grep -c "\"rid\":\"$RID\"" "$tmp/devstate/tag-yes.jsonl")" = 1 ] \
  && pass "trick dev --rid --state: the same rid twice writes one yes" || miss "trick dev --rid --state"
: > "$tmp/gh.log"

step "all seven green: the Decision" "$timer" "{\"parts\":[\"tabbar\",\"session\"],\"tabbar\":\"Gates 7/7\",\"status\":null,\"decisions\":[\"$K\"],\"recommends\":{\"$K\":\"tag\"},\"confirm\":{\"$K\":\"tag\"},\"has\":[\"Tag and push v$V?\",\"Hold for 24 h\",\"All seven gates are green.\",\"Again: tag v$V\",\"Tag and push\",\"| 1 CI on main | green |\",\"3/3, replay, 2026-11-09\",\"41/41, 2.4.0, 2026-11-09\",\"rollback: ok\",\"2.4.0 on top, 1 bullets\",\"counsel note, 2026-11-09\",\"No session is named release\",\"answers are recorded here only\"],\"view\":{\"$K\":[\"Gates\",\"1 CI on main\",\"012345678 success\",\"3/3 replay\",\"41/41\",\"rollback: ok\",\"2.4.0 on top\",\"no hold file\",\"note of 2026-11-09\",\"https://github.com/example/repo/actions/runs/101\"]},\"replyTo\":{\"$K\":null},\"about\":{\"$K\":null},\"texts\":{\"$K\":\"none\"},\"summaryStarts\":{\"$K\":\"Your yes goes to the release session, which tags and pushes v$V.\"},\"summaryEnds\":{\"$K\":\"All seven gates are green.\"},\"lacks\":[\"(dry run)\",\"Dry run\"]}"
printf '%s' "$out" | "$BUN" -e '
const d = JSON.parse(await Bun.stdin.text());
const s = d.parts.find((p) => p.at === "session").view.find((n) => n.kind === "bar").kids.map((k) => k.text).join("");
const k = d.decisions[0].view[0].kids.map((c) => c.text + c.attrs.state).join(",");
if (s !== "1234567" || k !== "1done,2done,3done,4done,5done,6done,7done") { console.error("chips " + s + " " + k); process.exit(1); }' && pass "the chips carry the numbers 1 to 7, in the Session and on the Decision" || miss "the chips"
printf '%s' "$out" | "$BUN" -e '
const d = JSON.parse(await Bun.stdin.text());
const r = d.decisions[0];
const ok = r.recommends?.intent === "tag" && r.recommends.why === "All seven gates are green." && r.options.find((o) => o.intent === "tag")?.confirm !== undefined && r.options.every((o) => o.selected === undefined && o.default === undefined);
process.exit(ok ? 0 : 1)' && pass "the Decision recommends tag, why \"All seven gates are green.\", the confirm stays on the option" || miss "the recommendation of the tag Decision"
first=$(calls)
step "cache: a second run inside 60 s" "$timer" '{"tabbar":"Gates 7/7"}'
[ "$(calls)" = "$first" ] && pass "the second run called gh 0 times (first run: $first)" || miss "the second run called gh $(($(calls) - first)) times"
step "cache: a run after 61 s reads again" "$timer" '{"tabbar":"Gates 7/7"}' TRICK_NOW=$((NOW + 61))
[ "$(calls)" -gt "$first" ] || miss "a run after 61 s did not read again"

# Where the count shows is the setting `show`.
config "$V" true results logs "$fix/rehearsal-ok.txt" 'show = ["status"]\n'
step "show status: the chip gates 7/7" "$timer" '{"parts":["status","session"],"status":"gates 7/7","tabbar":null}'
config "$V" true results logs "$fix/rehearsal-ok.txt" 'show = ["dashboard", "belt"]\n'
step "show dashboard and belt" "$timer" '{"parts":["dashboard","belt","session"],"dashboard":"Gates 7/7","belt":"gates 7/7"}'
config "$V" true results logs "$fix/rehearsal-ok.txt" 'show = ["menu"]\n'
step "an unknown word: only the Session, one warn row" "$timer" '{"parts":["session"],"has":["show names \"menu\", which this trick ignores"]}'
config "$V" true results logs "$fix/rehearsal-ok.txt"

export SESSIONS='[{"id":"laptop:w9:2","memberId":"laptop","sessionId":"laptop:w9:2","paneId":"w9:2","host":"laptop","name":"Release","status":"idle"},{"id":"laptop:w9:4","memberId":"laptop","sessionId":"laptop:w9:4","paneId":"w9:4","host":"laptop","name":"release 2","status":"idle"}]'
step "a name that differs by case or a suffix does not match" "$timer" "{\"decisions\":[\"$K\"],\"replyTo\":{\"$K\":null},\"has\":[\"answers are recorded here only\"]}"
export SESSIONS='[{"id":"laptop:w9:3","memberId":"laptop","sessionId":"laptop:w9:3","paneId":"w9:3","host":"laptop","name":"release","agent":"alpha","status":"idle","cwd":"/home/dev/app"}]'
step "a session named release: about and replyTo" "$timer" "{\"decisions\":[\"$K\"],\"replyTo\":{\"$K\":\"laptop:w9:3\"},\"about\":{\"$K\":\"laptop:w9:3\"},\"lacks\":[\"No session is named release\",\"answers are recorded here only\"]}"
tag="{\"kind\":\"tap\",\"rid\":\"r-tag-1\",\"node\":\"hill/$K\",\"intent\":\"tag\",\"value\":{\"text\":null},\"seen\":\"944a71314b332828\"}"
step "tap tag: a yes record, no tag" "$tag" "{\"tabbar\":\"Gates 7/7\",\"decisions\":[],\"has\":[\"Yes for v$V recorded.\",\"Yes given for v$V\",\"The release session tags and pushes.\"]}"
step "the same rid again" "$tag" '{"decisions":[],"has":["This tap was recorded already."]}'
[ "$(wc -l < "$tmp/state/tag-yes.jsonl")" = 1 ] && pass "a repeated rid writes one record" || miss "a repeated rid wrote twice"
grep -q '"rid":"r-tag-1"' "$tmp/state/tag-yes.jsonl" && grep -q '"answer":"yes"' "$tmp/state/tag-yes.jsonl" || miss "the yes record lacks the rid or the answer"
grep -q '"seen":"944a71314b332828"' "$tmp/state/tag-yes.jsonl" || miss "the yes record lacks seen"
unset SESSIONS

fresh
step "tap not-yet: closed for 24 h" "{\"kind\":\"tap\",\"rid\":\"r-wait-1\",\"node\":\"hill/$K\",\"intent\":\"not-yet\",\"value\":{\"text\":null}}" '{"tabbar":"Gates 7/7","decisions":[],"has":["closed for 24 h"]}'
step "after 24 h it asks again" "$timer" "{\"decisions\":[\"$K\"]}" TRICK_NOW=$((NOW + 86500))

fresh
dis="{\"kind\":\"tap\",\"rid\":\"r-dis-1\",\"node\":\"hill/$K\",\"intent\":\"dismiss\",\"value\":{\"text\":null},\"seen\":\"d15d000012345678\"}"
step "tap dismiss: closed for 24 h, no yes" "$dis" '{"tabbar":"Gates 7/7","decisions":[],"has":["is dismissed, closed for 24 h."]}'
step "the same dismiss rid again" "$dis" '{"decisions":[],"has":["This tap was recorded already."]}'
[ "$(wc -l < "$tmp/state/tag-dismissed.jsonl")" = 1 ] && grep -q '"seen":"d15d000012345678"' "$tmp/state/tag-dismissed.jsonl" || miss "the dismiss record is missing, doubled or lacks seen"
[ ! -f "$tmp/state/tag-yes.jsonl" ] || miss "a dismiss wrote a yes"
step "still closed after 23 h" "$timer" '{"decisions":[]}' TRICK_NOW=$((NOW + 82800))
step "after 24 h the key is listed again (the re-ask)" "$timer" "{\"decisions\":[\"$K\"]}" TRICK_NOW=$((NOW + 86500))

fresh; echo "release 2.3.5 is being cut by another session" > "$rel/hold"
step "a hold file turns gate 6 red" "$timer" '{"tabbar":"Gates 6/7","decisions":[],"has":["First red gate: No peer release","release 2.3.5 is being cut"]}'
step "tap tag while a gate is red: not recorded" "$tag" '{"decisions":[],"has":["Not recorded: 6 of 7 gates are green."]}'
[ ! -f "$tmp/state/tag-yes.jsonl" ] || miss "a tag tap with a red gate wrote a yes"

fresh; rm -rf "$tmp/state"/cache-*
step "red CI: the failed job is the tail, on top" "$timer" '{"tabbar":"Gates 6/7","decisions":[],"has":["First red gate: CI on main","fedcba987, failure","job test (ubuntu): failure","step bun test: failure"]}' FAKE_CI=failure
printf '%s' "$out" | "$BUN" -e 'const d = JSON.parse(await Bun.stdin.text()); const kinds = d.parts.find((p) => p.at === "session").view.map((n) => n.kind).join(","); process.exit(kinds.startsWith("number,card,code,bar,list") ? 0 : 1)' && pass "the first red gate and its tail stand above the rows" || miss "the order of the Session"

fresh; config "$V" true results-red logs "$fix/rehearsal-ok.txt"
step "a red leg case is the tail" "$timer" '{"tabbar":"Gates 6/7","decisions":[],"has":["First red gate: Browser leg","2/3, replay, 2026-11-09","gamma 4 upload while offline: fail"]}'

fresh; config "$V" true results logs-red "$fix/rehearsal-ok.txt"
fake="sk-or-v1-0000000000fakefakefake0000000000"
step "a red core leg: the tail is masked" "$timer" "{\"tabbar\":\"Gates 6/7\",\"has\":[\"First red gate: Core legs\",\"32/34\",\"2 [phone]\",\"sk-o****\"],\"lacks\":[\"$fake\",\"fakefake\"]}"

fresh; config "$V" true results logs ""
step "no rehearsal file: idle, no report, not red" "$timer" '{"tabbar":"Gates 6/7","decisions":[],"has":["4 Windows rehearsal","not yet","no report"],"lacks":["First red gate"]}'
config "$V" false results logs ""
step "minor = false skips the rehearsal" "$timer" "{\"tabbar\":\"Gates 7/7\",\"decisions\":[\"$K\"],\"has\":[\"not a minor: the rehearsal is skipped\"],\"view\":{\"$K\":[\"skipped, not a minor\"]}}"

config "$V" true results logs "$fix/rehearsal-ok.txt"
step "bullets under Unreleased turn gate 5 red" "$timer" '{"tabbar":"Gates 6/7","decisions":[],"has":["First red gate: Changelog","Unreleased holds 1 bullets","The badge keeps its frame."]}' FAKE_CHANGELOG=unreleased
step "a top section of another version is red" "$timer" '{"tabbar":"Gates 6/7","has":["the top section is 2.4.1, not 2.4.0"]}' FAKE_CHANGELOG=patch
step "a version tagged already is red, older reports are idle" "$timer" "{\"tabbar\":\"Gates 3/7\",\"has\":[\"v$V is tagged already\",\"the counsel note is older than v$V\",\"no report since v$V: run 2026-11-09T10-00 is older\",\"no report since v$V: leg-core-2.4.0.txt is older\"]}" FAKE_TAGGED=$V

echo "counsel for something else" > "$rel/counsel.md"
step "a counsel note that names another version is red" "$timer" "{\"tabbar\":\"Gates 6/7\",\"has\":[\"the counsel note does not name $V\"]}"
rm "$rel/counsel.md"
step "no counsel note: idle" "$timer" '{"tabbar":"Gates 6/7","has":["7 Counsel done"],"lacks":["First red gate"]}'

fresh
out=$(facts "$timer" | (cd "$work" && env PATH="$tmp/nobin" TRICK_TOOLS_ONLY_PATH=1 TRICK_NOW=$NOW "$BUN" ./program.ts) 2>/dev/null)
printf '%s' "$out" | "$BUN" "$tmp/assert.ts" '{"tabbar":"Gates 5/7","has":["no report: gh not found","5 Changelog"],"lacks":["First red gate"]}' $PLACES && pass "gh and git missing: idle gates" || miss "gh and git missing"

config "" true results logs ""
step "no version: one muted row and nothing else" "$timer" '{"parts":["session"],"tabbar":null,"status":null,"decisions":[],"has":["no release open"]}'
config "$V" true results logs ""
step "TRICK_FIXTURE=all-green shows the Decision" "$timer" "{\"tabbar\":\"Gates 7/7\",\"decisions\":[\"$K\"],\"has\":[\"fixture: forced green\",\"fixture: all-green\"]}" TRICK_FIXTURE=all-green

# The program writes only to its state folder: a fresh copy, listed before and after a run, a yes, the same yes,
# and a not-yet on a second version.
clean=$tmp/clean
cp -r "$here" "$clean" && rm -rf "$clean/media"
fresh
DIR=$clean config "$V" true results logs "$fix/rehearsal-ok.txt"
list() { (cd "$clean" && find . -path ./media -prune -o -type f -print | sort | xargs md5sum); }
was=$(list)
export DIR=$clean STATE=$tmp/state2
step "fresh copy: timer" "$timer" "{\"decisions\":[\"$K\"]}"
step "fresh copy: yes" "$tag" '{"decisions":[]}'
step "fresh copy: the same yes" "$tag" '{"has":["This tap was recorded already."]}'
unset DIR STATE
[ "$was" = "$(list)" ] && pass "the trick folder is unchanged" || miss "the program wrote into its own folder"
[ "$(ls "$tmp/state2" | tr '\n' ' ')" = "cache-ci.json tag-yes.jsonl " ] && pass "the state folder holds the CI cache and the yes" || miss "state folder: $(ls "$tmp/state2" | tr '\n' ' ')"
[ "$(wc -l < "$tmp/state2/tag-yes.jsonl")" = 1 ] && pass "fresh copy: one record for one rid" || miss "fresh copy: the rid wrote twice"

# Never a tag, a push or a release: every call gh and git saw is a read verb.
if grep -hq '^WRITE' "$tmp/gh.log" "$tmp/git.log"; then miss "a write verb reached gh or git"; else pass "gh and git saw read verbs only ($(cut -d' ' -f2,3 "$tmp/gh.log" | sort -u | tr '\n' ',' | sed 's/,$//'); git $(sed 's/^git -C [^ ]* //' "$tmp/git.log" | cut -d' ' -f1 | sort -u | tr '\n' ' '))"; fi
grep -hE '^git (-C [^ ]+ )?(tag|push)( |$)|^gh (release|api)' "$tmp/git.log" "$tmp/gh.log" && miss "a tag, a push or a release ran" || pass "no tag, no push, no release command ran"

[ "$failed" = 0 ] && echo "all ok" || { echo "FAILED"; exit 1; }
