#!/bin/sh
# Checks the Triage trick on a copy of this folder, with no network: a fake gh on PATH serves the open
# list (fixtures/gh/, made-up data for example/repo) and logs every call, and a fake git answers
# user.name. With live = false gh must see read verbs only. Ends with "all ok". Needs sh, bun, and a Collie
# source checkout with trick support (COLLIE_REPO), whose CLI runs `trick check` and `trick dev`.
here=$(cd "$(dirname "$0")" && pwd)
repo=${COLLIE_REPO:-}
schema=$repo/web/src/lib/tricks/schema.ts
[ -f "$schema" ] || { echo "set COLLIE_REPO to a Collie source checkout that has trick support (cli/main.ts and web/src/lib/tricks/schema.ts); no schema at $schema" >&2; exit 2; }
BUN=$(command -v bun) || { echo "no bun on PATH" >&2; exit 2; }
BUNDIR=$(dirname "$BUN")
PLACES=dashboard,tabbar,status,belt,session

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -r "$here" "$tmp/triage"
work=$tmp/triage
fix=$work/fixtures
drafts=$tmp/drafts
cp -r "$fix/drafts" "$drafts"
touch -d "2026-11-09 12:00 UTC" "$drafts"/*
sed "s#SCHEMA#$schema#" "$fix/assert.ts.in" > "$tmp/assert.ts"
mkdir "$tmp/state" "$tmp/bin" "$tmp/comments"
config() { # LIVE NAMES [EXTRA LINE]
  printf 'repo = "example/repo"\ndrafts = "%s"\nlive = %s\nreply_session = "triage worker"\nnames = [%s]\n%b' "${DRAFTS:-$drafts}" "$1" "$2" "${3:-}" > "${DIR:-$work}/config.toml"
}
config false '"Jordan", "Quill"'

# The fake gh: the read verbs answer from the fixtures; a comment answers a URL and is logged as COMMENT;
# anything else is logged as WRITE and fails. FAKE_FAIL=1 makes every call fail.
cat > "$tmp/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$tmp/gh.log"
[ "\${FAKE_FAIL:-0}" = 1 ] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
case "\$1 \$2" in
  "pr list") cat "$fix/gh/prs.json" ;;
  "issue list") cat "$fix/gh/issues.json" ;;
  "api -X")
    case "\$4" in
      user) echo "op-login" ;;
      repos/*/comments) n=\$(echo "\$4" | sed 's#.*/issues/\([0-9]*\)/comments#\1#')
        if [ -f "$tmp/comments/\$n.json" ]; then cat "$tmp/comments/\$n.json"; elif [ -f "$fix/gh/comments-\$n.json" ]; then cat "$fix/gh/comments-\$n.json"; else echo "[]"; fi ;;
      *) echo "WRITE \$*" >> "$tmp/gh.log"; exit 1 ;;
    esac ;;
  "pr comment"|"issue comment")
    echo "COMMENT \$*" >> "$tmp/gh.log"
    [ "\${FAKE_POST_FAIL:-0}" = 1 ] && { echo "GraphQL: rate limited" >&2; exit 1; }
    kind=pull; [ "\$1" = issue ] && kind=issues
    echo "https://github.com/example/repo/\$kind/\$3#issuecomment-900\$3" ;;
  *) echo "WRITE \$*" >> "$tmp/gh.log"; exit 1 ;;
esac
EOF
cat > "$tmp/bin/git" <<EOF
#!/bin/sh
echo "git \$*" >> "$tmp/git.log"
[ "\$1 \$2 \$3" = "config --global user.name" ] && { echo "Jordan Quill"; exit 0; }
exit 1
EOF
chmod +x "$tmp/bin/gh" "$tmp/bin/git"
: > "$tmp/gh.log"

failed=0
pass() { echo "ok   $1"; }
miss() { echo "FAIL $1"; failed=1; }
writes() { grep -c '^COMMENT\|^WRITE' "$tmp/gh.log"; }
NOW=1794227400
facts() {
  printf '{"contract":1,"trigger":%s,"trick":{"id":"triage","dir":"%s","state":"%s"},"memberId":"laptop","host":"laptop","sessions":%s,"spaces":[]}' "$1" "${DIR:-$work}" "${STATE:-$tmp/state}" "${SESSIONS:-[]}"
}
WITH_TRIAGE='[{"id":"laptop:w9:4","memberId":"laptop","sessionId":"laptop:w9:4","paneId":"w9:4","host":"laptop","name":"triage worker","agent":"claude","status":"idle","cwd":"/home/dev"}]'
# step NAME TRIGGER_JSON EXPECT_JSON [ENV...]. A fixed clock: 2026-11-09 12:30 UTC.
step() {
  name=$1 trig=$2 want=$3
  shift 3
  out=$(facts "$trig" | (cd "${DIR:-$work}" && env PATH="$tmp/bin:$BUNDIR:/usr/bin:/bin" TRICK_TOOLS_ONLY_PATH=1 TRICK_NOW=$NOW "$@" "$BUN" ./program.ts) 2>"$tmp/stderr") || { miss "$name: exited non-zero"; cat "$tmp/stderr"; return; }
  if printf '%s' "$out" | "$BUN" "$tmp/assert.ts" "$want" $PLACES; then pass "$name"; else miss "$name"; fi
}
calls() { wc -l < "$tmp/gh.log" | tr -d ' '; }
fresh_state() { rm -rf "$tmp/state"; mkdir "$tmp/state"; }
cli() { (cd "$repo" && env PATH="$tmp/bin:$BUNDIR:/usr/bin:/bin" HOME="$HOME" COLLIE_STATE_DIR="$tmp/cli-state" HERDR_PLUGIN_CONFIG_DIR="$tmp/cli-config" "$BUN" cli/main.ts "$@"); }
timer='{"kind":"timer"}'

# ── The platform's own checks ──
if cli trick check --run "$work" > "$tmp/check.txt" 2>&1 && grep -q '^ok: no problems.' "$tmp/check.txt"; then pass "trick check --run: no refusal"; else miss "trick check --run"; cat "$tmp/check.txt"; fi
grep -q 'env:    DBUS_SESSION_BUS_ADDRESS' "$tmp/check.txt" && pass "trick check lists the env name" || miss "trick check does not list DBUS_SESSION_BUS_ADDRESS"
cli trick dev "$work" --json > "$tmp/dev.json" 2>&1
if "$BUN" -e '
const d = JSON.parse(await Bun.file(process.argv[1]).text());
const at = d.parts.map((p) => p.part.at + ":" + p.part.id).join(",");
const keys = d.decisions.map((x) => x.key).join(",");
const r = d.decisions.find((x) => x.key === "reply-14");
const flat = JSON.stringify(r?.view ?? []);
const ok = d.outcome === "exited" && d.refusals.length === 0 && at === "dashboard:dashboard,session:main" && d.parts[0].part.item.badge === 3 && keys === "reply-12,reply-14,merge-14,reply-15"
  && r.summary.startsWith("Dry run: Post only records the reply. It opens: “") && flat.includes("House check") && flat.includes("CI green") && flat.includes("@ben: The plain spawn") && flat.includes("Thanks @ben, I am taking this");
if (!ok) { console.error(JSON.stringify({ at, keys, outcome: d.outcome, problem: d.problem, refusals: d.refusals, flat })); process.exit(1); }' "$tmp/dev.json"; then pass "trick dev --json: a tile with 3, the Session, four Decisions with their views"; else miss "trick dev --json"; fi
cli trick dev "$work" --json --tap edit --text "Say which release carries it." --node hill/reply-15 > "$tmp/devtap.json" 2>&1
grep -q 'are kept here: no session is named triage worker.' "$tmp/devtap.json" && grep -q '"refusals": \[\]' "$tmp/devtap.json" && pass "trick dev --tap edit --node hill/reply-15: the words are taken" || miss "trick dev --tap edit"
[ "$(writes)" = 0 ] && pass "trick dev with live off: gh saw read verbs only" || miss "trick dev wrote through gh"
[ ! -e "$drafts/15.edit.md" ] && pass "an edit writes nothing beside the draft" || miss "an edit wrote beside the draft"
# One request id, a kept state folder: the timer run offers the draft, then the same Post tap twice is one would record.
RID=5c1d2e3f-4a5b-4c6d-8e7f-9a0b1c2d3e4f
cli trick dev "$work" --json --state "$tmp/devstate" > /dev/null 2>&1
cli trick dev "$work" --json --tap post --node hill/reply-12 --rid $RID --state "$tmp/devstate" > "$tmp/devpost1.json" 2>&1
cli trick dev "$work" --json --tap post --node hill/reply-12 --rid $RID --state "$tmp/devstate" > "$tmp/devpost2.json" 2>&1
grep -q 'Would post to PR 12, live is off.' "$tmp/devpost1.json" && grep -q 'This tap was recorded already.' "$tmp/devpost2.json" \
  && [ "$(grep -c "\"rid\":\"$RID\",.*\"state\":\"would\"" "$tmp/devstate/posts.jsonl")" = 1 ] && [ "$(writes)" = 0 ] \
  && pass "trick dev --rid --state: the same Post rid twice is one would record, no gh write" || miss "trick dev --rid --state: $(cat "$tmp/devstate/posts.jsonl" 2>&1 | head -c 300)"
: > "$tmp/gh.log"

step "timer: three offered, one refused" "$timer" '{"parts":["dashboard","session"],"dashboard":"Triage 3","decisions":["reply-12","reply-14","merge-14","reply-15"],"has":["The house check passes and CI is green.","Tap again: post","Tap again: merge","Not offered: the reply to PR 11","a praise word: \"great\"","great work on the raw read","Pull requests","Issues","https://github.com/example/repo/pull/15","No session is named triage worker","answers are recorded here only"],"recommends":{"reply-12":"post","reply-14":"post","reply-15":"post"},"texts":{"reply-12":"optional","reply-14":"optional","reply-15":"optional","merge-14":"none"},"titleEnds":{"reply-12":")?","reply-14":")?","merge-14":")?"},"summaryStarts":{"reply-12":"Dry run: Post only records the reply. It opens: “","reply-15":"Dry run: Post only records the reply. It opens: “","merge-14":"Dry run: nothing is merged. "},"confirm":{"reply-14":"post","merge-14":"merge"},"view":{"reply-14":["House check","no key","no name","no em dash","no date","no praise","plain","CI green","PR 14","Last comment","@ben: The plain spawn","The draft","Thanks @ben, I am taking this"],"reply-15":["CI green","Thanks @cleo"]},"body":{"reply-15":["Until I have tried it on a phone the branch stays open"]},"noView":["merge-14"],"lacks":["—"]}'
printf '%s' "$out" | "$BUN" -e 'const d = JSON.parse(await Bun.stdin.text()); const r = d.decisions.find((x) => x.key === "reply-15"); const p = JSON.stringify(r.view).includes("Last comment"); const t = r.view.at(-1).text; process.exit(!p && t.length <= 240 && t.endsWith("...") ? 0 : 1)' && pass "no thread comment: no Last comment; the draft in the view is cut at 240" || miss "the view of reply-15"
grep -q 'doctor: draft 11 refused: a praise word' "$tmp/stderr" || miss "no doctor line for the refused draft"
first=$(calls)
step "cache: a second run inside 60 s" "$timer" '{"dashboard":"Triage 3"}'
[ "$(calls)" = "$first" ] && pass "the second run called gh 0 times (first run: $first)" || miss "the second run called gh $(($(calls) - first)) times"
step "cache: a run after 61 s reads again" "$timer" '{"dashboard":"Triage 3"}' TRICK_NOW=$((NOW + 61))
[ "$(calls)" -gt "$first" ] || miss "a run after 61 s did not read again"

# Where the count shows is the setting `show`.
config false '"Jordan", "Quill"' 'show = ["status"]\n'
step "show status: a status chip, no tile" "$timer" '{"parts":["status","session"],"status":"triage 3","dashboard":null}'
config false '"Jordan", "Quill"' 'show = ["belt"]\n'
step "show belt: a Belt mark" "$timer" '{"parts":["belt","session"],"belt":"triage 3","status":null}'
config false '"Jordan", "Quill"' 'show = ["glow", "tabbar"]\n'
step "an unknown word is a warn row; tabbar shows" "$timer" '{"parts":["tabbar","session"],"tabbar":"Triage 3","has":["show names \"glow\", which this trick ignores"]}'
config false '"Jordan", "Quill"' 'mark = "status"\n'
step "the old mark key: the default places and a warn row" "$timer" '{"parts":["dashboard","session"],"has":["mark is gone"]}'
config false '"Jordan", "Quill"'
step "a failed read serves the cached copy with its age" "$timer" '{"dashboard":"Triage 3","has":["gh read failed: HTTP 502: bad gateway, showing the read of 2 min ago"]}' TRICK_NOW=$((NOW + 181)) FAKE_FAIL=1

export SESSIONS=$WITH_TRIAGE
step "a session named triage worker gets replyTo, unchanged" "$timer" '{"decisions":["reply-12","reply-14","merge-14","reply-15"],"replyTo":{"reply-12":"laptop:w9:4","merge-14":"laptop:w9:4"},"lacks":["answers are recorded here only"]}'
DECOY='[{"id":"laptop:w9:5","memberId":"laptop","sessionId":"laptop:w9:5","paneId":"w9:5","host":"laptop","name":"Triage Worker","status":"idle"},{"id":"laptop:w9:6","memberId":"laptop","sessionId":"laptop:w9:6","paneId":"w9:6","host":"laptop","name":"triage worker 2","status":"idle"}]'
export SESSIONS=$DECOY
step "a name that differs by case or a suffix does not match" "$timer" '{"replyTo":{"reply-12":null,"merge-14":null},"has":["answers are recorded here only"]}'
export SESSIONS=$WITH_TRIAGE

post='{"kind":"tap","rid":"r-post-1","node":"hill/reply-12","intent":"post","value":{"text":null},"seen":"c0ffee0012345678"}'
step "tap post, live off: a would record" "$post" '{"dashboard":"Triage 2","decisions":["reply-14","merge-14","reply-15"],"has":["Would post to PR 12, live is off.","would post","Dry run: nothing was posted, live is off.","Records"]}'
step "the same rid again" "$post" '{"dashboard":"Triage 2","has":["This tap was recorded already."]}'
[ "$(grep -c '"rid":"r-post-1"' "$tmp/state/posts.jsonl")" = 1 ] && pass "a repeated rid writes one record" || miss "a repeated rid wrote twice"
grep -q '"state":"would"' "$tmp/state/posts.jsonl" || miss "the post record is not a would record"
grep -q '"seen":"c0ffee0012345678"' "$tmp/state/posts.jsonl" || miss "the post record lacks seen"
grep '"rid":"r-post-1"' "$tmp/state/posts.jsonl" | grep -q '"hash":"[0-9a-z]\{8,12\}"' || miss "the post record lacks the guard hash"

edit='{"kind":"tap","rid":"r-edit-1","node":"hill/reply-15","intent":"edit","value":{"text":"Say which release carries it."},"seen":"beef000012345678"}'
step "tap edit: the words go to the triage agent" "$edit" '{"dashboard":"Triage 1","decisions":["reply-14","merge-14"],"has":["went to triage worker, the triage agent.","waits for the triage agent'"'"'s new version","Say which release carries it.","Sent to triage worker"]}'
step "the same edit rid again" "$edit" '{"dashboard":"Triage 1"}'
[ "$(wc -l < "$tmp/state/edits.jsonl")" = 1 ] && pass "a repeated edit rid writes one record" || miss "a repeated edit rid wrote twice"
grep -q '"seen":"beef000012345678".*"text":"Say which release carries it."' "$tmp/state/edits.jsonl" || miss "the edit record lacks seen or the words"
[ -f "$tmp/state/edit-15.json" ] && [ ! -e "$drafts/15.edit.md" ] && pass "the edit lives in the state folder, not beside the draft" || miss "the edit's place"
printf 'Thanks @cleo, I want to look at it on the phone first, and the release that carries it is named here once it exists.\n' > "$drafts/15.md"
touch -d "2026-11-09 12:10 UTC" "$drafts/15.md"
step "the agent's new version is offered again" "$timer" '{"dashboard":"Triage 2","decisions":["reply-14","merge-14","reply-15"],"has":["the release that carries it"]}'

merge='{"kind":"tap","rid":"r-merge-1","node":"hill/merge-14","intent":"merge","value":{"text":null},"seen":"fade000012345678"}'
step "tap merge: always a would record" "$merge" '{"decisions":["reply-14","reply-15"],"has":["Would merge PR 14 into the base branch, merge has no live path yet.","would merge","Dry run: nothing was merged."]}'
grep -q '"seen":"fade000012345678"' "$tmp/state/would-merge.jsonl" || miss "the merge record lacks seen"
hold='{"kind":"tap","rid":"r-hold-1","node":"hill/reply-14","intent":"hold","value":{"text":null}}'
step "tap hold: closed for 24 h" "$hold" '{"dashboard":"Triage 1","decisions":["reply-15"],"has":["Held: the reply to PR 14"]}'
step "after 24 h the hold is over" "$timer" '{"decisions":["reply-14","reply-15"]}' TRICK_NOW=$((NOW + 86500))

# A dismiss on both keys: a record with seen, the key closed for 24 h, no act. Then the re-ask after 24 h.
fresh_state
step "dismiss setup: four Decisions" "$timer" '{"decisions":["reply-12","reply-14","merge-14","reply-15"]}'
d1='{"kind":"tap","rid":"r-dis-1","node":"hill/reply-12","intent":"dismiss","value":{"text":null},"seen":"d15d000012345678"}'
step "tap dismiss on a reply" "$d1" '{"decisions":["reply-14","merge-14","reply-15"],"has":["Dismissed the reply to PR 12, closed for 24 h.","Dismissed: the reply to PR 12, until 2026-11-10"],"lacks":["Held:"]}'
d2='{"kind":"tap","rid":"r-dis-2","node":"hill/merge-14","intent":"dismiss","value":{"text":null},"seen":"d15d000087654321"}'
step "tap dismiss on a merge" "$d2" '{"decisions":["reply-14","reply-15"],"has":["Dismissed the merge of PR 14, closed for 24 h."]}'
step "the same dismiss rid again" "$d2" '{"has":["This tap was recorded already."]}'
[ "$(wc -l < "$tmp/state/dismissed.jsonl")" = 2 ] || miss "a dismiss was not recorded exactly once per rid"
grep -q '"key":"reply-12".*"seen":"d15d000012345678"' "$tmp/state/dismissed.jsonl" && grep -q '"key":"merge-14".*"seen":"d15d000087654321"' "$tmp/state/dismissed.jsonl" || miss "a dismiss record lacks key or seen"
[ ! -f "$tmp/state/posts.jsonl" ] && [ ! -f "$tmp/state/would-merge.jsonl" ] || miss "a dismiss acted"
step "still closed after 23 h" "$timer" '{"decisions":["reply-14","reply-15"]}' TRICK_NOW=$((NOW + 82800))
step "after 24 h both keys are listed again (the re-ask)" "$timer" '{"decisions":["reply-12","reply-14","merge-14","reply-15"],"lacks":["Dismissed:"]}' TRICK_NOW=$((NOW + 86500))

# The merge guard: the verdict changed after the Decision was shown, so a merge tap records nothing.
fresh_state
step "merge guard setup" "$timer" '{"decisions":["reply-12","reply-14","merge-14","reply-15"]}'
cp "$drafts/14.verdict" "$tmp/14.verdict.keep"
printf 'Approve, but wait for the second look.\n' > "$drafts/14.verdict"
step "a changed verdict: the merge tap records nothing" '{"kind":"tap","rid":"r-merge-g","node":"hill/merge-14","intent":"merge","value":{"text":null},"seen":"fade000012345678"}' '{"has":["is not the one that was shown, so nothing was recorded"]}'
[ ! -f "$tmp/state/would-merge.jsonl" ] || miss "a changed verdict was recorded as a merge"
cp "$tmp/14.verdict.keep" "$drafts/14.verdict"

[ "$(writes)" = 0 ] && pass "live off: gh saw read verbs only" || miss "live off, but gh saw a write"

# live = false makes zero gh write calls: every answer on every key, twice, on a fresh state and log.
fresh_state; : > "$tmp/gh.log"
step "live off, the full round: setup" "$timer" '{"decisions":["reply-12","reply-14","merge-14","reply-15"]}'
for tap in "$post" '{"kind":"tap","rid":"r-p2","node":"hill/reply-14","intent":"post","value":{"text":"now"}}' "$merge" "$edit" "$hold" "$d1"; do
  step "live off: $(printf '%s' "$tap" | sed 's/.*"intent":"\([a-z-]*\)".*/\1/') on $(printf '%s' "$tap" | sed 's/.*"node":"hill\/\([a-z0-9-]*\)".*/\1/')" "$tap" '{}'
  step "live off: the same rid again" "$tap" '{}'
done
[ "$(writes)" = 0 ] && [ "$(grep -c '"state":"would"' "$tmp/state/posts.jsonl")" = 2 ] && pass "live off: zero gh write calls, two would records" || miss "live off: $(writes) gh writes"
grep -q '"state":"started"\|"state":"posted"' "$tmp/state/posts.jsonl" && miss "live off wrote a started or posted record"

# The house rules, one draft each, on a fresh state folder.
fresh_state
rm -f "$drafts"/*
printf 'Thanks @cleo, Jordan looks at it first.\n' > "$drafts/15.md"
printf 'Thanks @ana, I keep the commits \342\200\224 all of them.\n' > "$drafts/12.md"
printf 'Thanks @ben, this lands by Friday.\n' > "$drafts/14.md"
printf 'Thanks @ana, it goes in on Nov 20.\n' > "$drafts/11.md"
printf 'Thanks @a, I keep it.\n- one\n- two\n' > "$drafts/10.md"
printf '# Verdict\nThanks @b, I keep it.\n' > "$drafts/9.md"
printf 'Thanks @c, this is in!\n' > "$drafts/8.md"
printf 'Thanks @d, I keep it.\n\nA second paragraph.\n' > "$drafts/7.md"
touch -d "2026-11-09 12:00 UTC" "$drafts"/*
step "each house rule refuses a draft" "$timer" '{"status":null,"dashboard":"Triage","decisions":[],"has":["the operator'"'"'s name","[name] looks at it first","an em dash","a date promise: \"by Friday\"","a date promise: \"Nov 20\"","a bullet list or a header","- one","# Verdict","an exclamation mark","more than one paragraph","A second paragraph."],"lacks":["Jordan"]}'

# The thread moved, and a thread whose newest comment is the login's own.
fresh_state
rm -f "$drafts"/*
printf 'Thanks @ana, I keep your commits as they are.\n' > "$drafts/12.md"
printf 'Thanks @cleo, I want to look at it on the phone first.\n' > "$drafts/15.md"
touch -d "2026-11-09 12:00 UTC" "$drafts"/*
printf '[{"user":{"login":"ana","type":"User"},"created_at":"2026-11-09T12:20:00Z"},{"user":{"login":"github-actions[bot]","type":"Bot"},"created_at":"2026-11-09T12:25:00Z"}]' > "$tmp/comments/12.json"
printf '[{"user":{"login":"cleo","type":"User"},"created_at":"2026-11-09T11:00:00Z"},{"user":{"login":"op-login","type":"User"},"created_at":"2026-11-09T11:30:00Z"}]' > "$tmp/comments/15.json"
step "the thread moved; the login's own reply drops out" "$timer" '{"status":null,"decisions":[],"has":["the thread moved since this draft","a comment from @ana, 2026-11-09 12:20 UTC","answered"],"lacks":["the reply to PR 15"]}'
rm -f "$tmp/comments"/*

# The name from git when config.toml names none.
fresh_state
config false ''
rm -f "$drafts"/*
printf 'Thanks @cleo, Quill will look at it.\n' > "$drafts/15.md"
step "names from git config" "$timer" '{"decisions":[],"has":["the operator'"'"'s name","[name] will look at it"],"lacks":["Quill"]}'
config false '"Jordan", "Quill"'

# The mask: a fake key in a draft never reaches the document, and the draft is not offered.
fresh_state
rm -f "$drafts"/*
fake="sk-or-v1-0000000000fakefakefake0000000000"
printf 'Thanks @ana, I keep your commits; the log showed %s by mistake.\n' "$fake" > "$drafts/12.md"
step "a key in a draft is masked and refused" "$timer" "{\"status\":null,\"decisions\":[],\"has\":[\"sk-o****\",\"a key, a token or a home path\"],\"lacks\":[\"$fake\",\"fakefake\"]}"

# The advice on a reply: Post on green CI or an issue, Hold on red or pending CI, nothing for a PR with no CI.
# The fake gh reads prs.json from the copy, so the copy is changed here and put back after.
fresh_state
rm -f "$drafts"/*
printf 'Thanks @ana, I keep your commits as they are.\n' > "$drafts/12.md"
printf 'Thanks @ben, I am taking this.\n' > "$drafts/14.md"
printf 'Thanks @cleo, I want to look at it on the phone first.\n' > "$drafts/15.md"
printf 'Thanks @someone, I can reproduce it with the steps you gave.\n' > "$drafts/21.md"
touch -d "2026-11-09 12:00 UTC" "$drafts"/*
step "advice: green PRs and an issue" "$timer" '{"decisions":["reply-12","reply-14","reply-15","reply-21"],"recommends":{"reply-12":"post","reply-14":"post","reply-21":"post","reply-15":"post"},"has":["The house check passes and CI is green.","The house check passes."],"lacks":["CI is red on this pull request.","CI still runs."],"summaryStarts":{"reply-12":"Dry run: Post only records the reply. It opens: “","reply-21":"Dry run: Post only records the reply. It opens: “"},"titleEnds":{"reply-12":")?"},"confirm":{"reply-12":"post"}}'
"$BUN" -e '
const f = process.argv[1];
const prs = JSON.parse(await Bun.file(f).text());
const set = (n, roll) => { prs.find((p) => p.number === n).statusCheckRollup = roll; };
const rolled = prs.find((p) => p.number === 12).statusCheckRollup;
set(12, [...rolled.slice(1), { ...rolled[0], conclusion: "FAILURE", status: "COMPLETED" }]);
set(14, [...rolled.slice(1), { ...rolled[0], conclusion: "", status: "IN_PROGRESS" }]);
set(15, []);
await Bun.write(f, JSON.stringify(prs));' "$fix/gh/prs.json"
fresh_state
step "advice: red CI recommends Hold, pending CI recommends Hold, no CI recommends nothing" "$timer" '{"decisions":["reply-12","reply-14","reply-15","reply-21"],"recommends":{"reply-12":"hold","reply-14":"hold","reply-21":"post","reply-15":null},"has":["CI is red on this pull request.","CI still runs.","The house check passes."],"lacks":["The house check passes and CI is green."],"summaryStarts":{"reply-12":"Dry run: Post only records the reply. It opens: “","reply-14":"Dry run: Post only records the reply. It opens: “"},"confirm":{"reply-12":"post","reply-14":"post"}}'
out=$(facts "$timer" | (cd "$work" && env PATH="$tmp/bin:$BUNDIR:/usr/bin:/bin" TRICK_TOOLS_ONLY_PATH=1 TRICK_NOW=$NOW "$BUN" ./program.ts) 2>/dev/null)
printf '%s' "$out" | "$BUN" -e '
const d = JSON.parse(await Bun.stdin.text());
const r = (k) => d.decisions.find((x) => x.key === k);
const ok = r("reply-12").recommends.why === "CI is red on this pull request." && r("reply-14").recommends.why === "CI still runs." && r("reply-21").recommends.why === "The house check passes." && r("reply-15").recommends === undefined
  && r("reply-12").options.map((o) => o.intent).join() === "post,edit,hold";
process.exit(ok ? 0 : 1)' && pass "advice: the why of each case, the options as before" || miss "advice: the why of each case"
cp "$here/fixtures/gh/prs.json" "$fix/gh/prs.json"
[ "$(writes)" = 0 ] && pass "advice: gh saw read verbs only" || miss "advice: a gh write"

# The live path, against the fake gh only: one comment per rid, the URL kept.
fresh_state
rm -f "$drafts"/*
printf 'Thanks @ana, I keep your commits as they are.\n' > "$drafts/12.md"
printf 'Thanks @someone, I can reproduce it with the steps you gave.\n' > "$drafts/21.md"
touch -d "2026-11-09 12:00 UTC" "$drafts"/*
config true '"Jordan", "Quill"'
step "live: two offered" "$timer" '{"decisions":["reply-12","reply-21"],"view":{"reply-21":["issue"]}}'
before=$(grep -c '^COMMENT' "$tmp/gh.log")
lpost='{"kind":"tap","rid":"r-live-1","node":"hill/reply-12","intent":"post","value":{"text":null}}'
step "live: post runs gh pr comment" "$lpost" '{"decisions":["reply-21"],"has":["Posted to PR 12.","https://github.com/example/repo/pull/12#issuecomment-90012"]}'
step "live: the same rid posts nothing" "$lpost" '{"has":["This tap was recorded already."]}'
[ "$(($(grep -c '^COMMENT' "$tmp/gh.log") - before))" = 1 ] && pass "live: one comment for one rid" || miss "live: $(($(grep -c '^COMMENT' "$tmp/gh.log") - before)) comments for one rid"
grep -q "^COMMENT pr comment 12 -R example/repo --body-file $drafts/12.md" "$tmp/gh.log" || miss "the comment call is not gh pr comment --body-file"
grep -q '"state":"posted","url":"https://github.com/example/repo/pull/12#issuecomment-90012"' "$tmp/state/posts.jsonl" || miss "the posted record has no URL"
printf 'Thanks @someone, I can reproduce it with the steps you gave, twice.\n' > "$drafts/21.md"
step "live: a draft changed since it was shown is not posted" '{"kind":"tap","rid":"r-live-2","node":"hill/reply-21","intent":"post","value":{"text":null}}' '{"has":["is not the one that was shown, so nothing was posted"]}'
step "live: a failed post is offered again" '{"kind":"tap","rid":"r-live-3","node":"hill/reply-21","intent":"post","value":{"text":null}}' '{"decisions":["reply-21"],"has":["Not posted to issue 21: GraphQL: rate limited","Tap Post the reply again to retry"]}' FAKE_POST_FAIL=1
step "live: an issue gets gh issue comment" '{"kind":"tap","rid":"r-live-4","node":"hill/reply-21","intent":"post","value":{"text":null}}' '{"decisions":[],"has":["Posted to issue 21."]}'
grep -q "^COMMENT issue comment 21 -R example/repo --body-file" "$tmp/gh.log" || miss "the issue comment call"
# live on: no dry-run words anywhere, on a reply or on a merge (merge says what a tap does instead).
fresh_state
rm -f "$drafts"/*
cp "$fix/drafts/14.md" "$fix/drafts/14.verdict" "$drafts/"
touch -d "2026-11-09 12:00 UTC" "$drafts"/*
step "live on: no dry-run words" "$timer" '{"decisions":["reply-14","merge-14"],"has":["Post the reply on PR 14 (use systemd-run","A tap is recorded for you, merge has no live path yet."],"lacks":["(dry run)","Dry run:","would post"]}'
config false '"Jordan", "Quill"'
grep -q '^WRITE' "$tmp/gh.log" && miss "a write verb other than comment reached gh" || pass "gh saw reads and the live comments only"

# gh missing: a card, no Decision, exit 0.
fresh_state
out=$(facts "$timer" | (cd "$work" && env PATH="$tmp/nobin" TRICK_TOOLS_ONLY_PATH=1 TRICK_NOW=$NOW "$BUN" ./program.ts) 2>/dev/null)
printf '%s' "$out" | "$BUN" "$tmp/assert.ts" '{"decisions":[],"has":["gh not found"]}' $PLACES && pass "gh missing: a card" || miss "gh missing"

# The program writes only to its state folder: a fresh copy whose drafts sit inside it, listed before and after
# a timer run, a post, an edit, a hold and a dismiss.
clean=$tmp/clean
cp -r "$here" "$clean" && rm -rf "$clean/media"
touch -d "2026-11-09 12:00 UTC" "$clean/fixtures/drafts"/*
DIR=$clean DRAFTS=fixtures/drafts config false '"Jordan", "Quill"'
list() { (cd "$clean" && find . -path ./media -prune -o -type f -print | sort | xargs md5sum); }
was=$(list); : > "$tmp/gh.log"
export DIR=$clean STATE=$tmp/state2 SESSIONS=$WITH_TRIAGE
step "fresh copy: timer" "$timer" '{"decisions":["reply-12","reply-14","merge-14","reply-15"]}'
for tap in "$post" "$edit" "$hold" "$d2"; do step "fresh copy: a tap" "$tap" '{}'; done
unset DIR STATE SESSIONS
[ "$was" = "$(list)" ] && pass "the trick folder, drafts included, is unchanged" || miss "the program wrote into its own folder"
[ "$(writes)" = 0 ] && pass "fresh copy: gh saw read verbs only" || miss "fresh copy: gh saw a write"
echo "state2: $(ls "$tmp/state2" | tr '\n' ' ')" | grep -q "closed.json.*edit-15.json.*edits.jsonl.*offered.json.*posts.jsonl" && pass "the state folder holds the records" || miss "state folder: $(ls "$tmp/state2" | tr '\n' ' ')"

[ "$failed" = 0 ] && echo "all ok" || { echo "FAILED"; exit 1; }
