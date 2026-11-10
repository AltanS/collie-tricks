#!/bin/sh
# Checks the Design Review trick on a copy of this folder, with no network and a fake git on PATH that logs every call.
# Ends with "all ok". Needs sh, bun, and a Collie source checkout with trick support (COLLIE_REPO),
# whose CLI runs `trick check` and `trick dev` from source with throwaway state and config folders.
here=$(cd "$(dirname "$0")" && pwd)
repo=${COLLIE_REPO:-}
schema=$repo/web/src/lib/tricks/schema.ts
[ -f "$schema" ] || { echo "set COLLIE_REPO to a Collie source checkout that has trick support (cli/main.ts and web/src/lib/tricks/schema.ts); no schema at $schema" >&2; exit 2; }
BUN=$(command -v bun) || { echo "no bun on PATH" >&2; exit 2; }
BUNDIR=$(dirname "$BUN")
PLACES=dashboard,tabbar,status,belt,session

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -r "$here" "$tmp/design-review"
work=$tmp/design-review
rm -rf "$work/media"
sed "s#SCHEMA#$schema#" "$here/fixtures/assert.ts.in" > "$tmp/assert.ts"
mkdir "$tmp/state" "$tmp/bin"
root=$work/fixtures/feat-example
uaconfig() { printf 'roots = ["%s/fixtures/*"]\nlane = "http://laptop:8788"\nreply_session = "reviewer"\n%b' "$work" "$1" > "$work/config.toml"; }
uaconfig ''

# The fake git: the four read verbs Design Review uses; anything else is logged as WRITE and fails.
cat > "$tmp/bin/git" <<EOF
#!/bin/sh
echo "\$*" >> "$tmp/git.log"
[ "\$1" = "-C" ] && shift 2
case "\$1" in
  rev-parse) echo true ;;
  branch) echo "\${FAKE_BRANCH:-feat/example}" ;;
  check-ignore) if [ "\${FAKE_IGNORED:-yes}" = yes ]; then printf 'LOOK.md\n.look/\n'; else exit 1; fi ;;
  status) [ "\${FAKE_TRACKED:-no}" = yes ] && echo "A  LOOK.md"; exit 0 ;;
  *) echo "WRITE \$*" >> "$tmp/git.log"; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/git"
: > "$tmp/git.log"
before=$(cd "$root" && find . -type f | sort | xargs md5sum)

failed=0
pass() { echo "ok   $1"; }
miss() { echo "FAIL $1"; failed=1; }
NOW=1794225600
# facts TRIGGER_JSON SESSION_CWD: a facts document like the bridge writes, with one worker session. EXTRA is
# more session objects, with a leading comma, for the name match. STATE overrides the state folder.
facts() {
  printf '{"contract":1,"trigger":%s,"trick":{"id":"design-review","dir":"%s","state":"%s"},"memberId":"laptop","host":"laptop","sessions":[{"id":"laptop:w1:1","memberId":"laptop","sessionId":"laptop:w1:1","paneId":"w1:1","host":"laptop","status":"idle","cwd":"/home/dev"},{"id":"laptop:w7:2","memberId":"laptop","sessionId":"laptop:w7:2","paneId":"w7:2","host":"laptop","name":"feature worker","agent":"claude","status":"working","cwd":"%s"}%s],"spaces":[]}' "$1" "${DIR:-$work}" "${STATE:-$tmp/state}" "$2" "${EXTRA:-}"
}
NAMED=',{"id":"laptop:w3:9","memberId":"laptop","sessionId":"laptop:w3:9","paneId":"w3:9","host":"laptop","name":"reviewer","agent":"claude","status":"idle","cwd":"/home/dev/reviewer"}'
DECOYS=',{"id":"laptop:w3:1","memberId":"laptop","sessionId":"laptop:w3:1","paneId":"w3:1","host":"laptop","name":"Reviewer","status":"idle","cwd":"/home/dev/a"},{"id":"laptop:w3:2","memberId":"laptop","sessionId":"laptop:w3:2","paneId":"w3:2","host":"laptop","name":"reviewer 2","status":"idle","cwd":"/home/dev/b"}'
# step NAME TRIGGER_JSON SESSION_CWD EXPECT_JSON [ENV...]: runs program.ts in the trick folder, as the bridge does.
step() {
  name=$1 trig=$2 cwd=$3 want=$4
  shift 4
  out=$(facts "$trig" "$cwd" | (cd "${DIR:-$work}" && env PATH="$tmp/bin:$BUNDIR:/usr/bin:/bin" TRICK_TOOLS_ONLY_PATH=1 TRICK_NOW=$NOW "$@" "$BUN" ./program.ts) 2>"$tmp/stderr") || { miss "$name: exited non-zero"; cat "$tmp/stderr"; return; }
  if printf '%s' "$out" | "$BUN" "$tmp/assert.ts" "$want" $PLACES; then pass "$name"; else miss "$name"; fi
}
calls() { wc -l < "$tmp/git.log" | tr -d ' '; }
cli() { (cd "$repo" && env PATH="$tmp/bin:$BUNDIR:/usr/bin:/bin" HOME="$HOME" COLLIE_STATE_DIR="$tmp/cli-state" HERDR_PLUGIN_CONFIG_DIR="$tmp/cli-config" "$BUN" cli/main.ts "$@"); }
K1=feat-example-the-sync-badge
K2=feat-example-the-detail-screen
K3=feat-example-settings-sync
K4=feat-example-the-copy-button-on-the-error-line
K5=feat-example-the-sync-page
timer='{"kind":"timer"}'

# ── The platform's own checks ──
if cli trick check --run "$work" > "$tmp/check.txt" 2>&1 && grep -q '^ok: no problems.' "$tmp/check.txt"; then pass "trick check --run: no refusal"; else miss "trick check --run"; cat "$tmp/check.txt"; fi
cli trick dev "$work" --json > "$tmp/dev.json" 2>&1
if "$BUN" -e '
const d = JSON.parse(await Bun.file(process.argv[1]).text());
const at = d.parts.map((p) => p.part.at + ":" + p.part.id).join(",");
const keys = d.decisions.map((x) => x.key).join(",");
const k1 = d.decisions.find((x) => x.key === process.argv[2]);
const ok = d.outcome === "exited" && d.refusals.length === 0 && at === "dashboard:dashboard,session:main" && d.parts[0].part.item.badge === 5
  && keys.split(",").length === 5 && k1?.title === "Ship “The sync badge”?" && k1.options.map((o) => o.label).join() === "Ship it,Keep the old look,Ask for a change" && k1.media.length === 1 && k1.options.map((o) => o.intent).join() === "yes,no,change";
if (!ok) { console.error(JSON.stringify({ at, keys, outcome: d.outcome, problem: d.problem, refusals: d.refusals })); process.exit(1); }' "$tmp/dev.json" "$K1"; then pass "trick dev --json: a tile with 5, the Session, five Decisions"; else miss "trick dev --json"; fi
cli trick dev "$work" --json --tap yes --node "hill/$K1" > "$tmp/devtap.json" 2>&1
if grep -q 'yes given for The sync badge.' "$tmp/devtap.json" && grep -q '"refusals": \[\]' "$tmp/devtap.json"; then pass "trick dev --tap yes --node hill/$K1: the answer is taken"; else miss "trick dev --tap"; fi
# trick dev on its own facts and a kept state folder: the session named reply_session gets replyTo, and one
# request id writes one record however often the tap comes.
EXTRA=$NAMED facts "$timer" "/home/dev/other" > "$tmp/named.json"
cli trick dev "$work" --json --facts "$tmp/named.json" > "$tmp/devnamed.json" 2>&1
"$BUN" -e 'const d = JSON.parse(await Bun.file(process.argv[1]).text()); process.exit(d.decisions.every((x) => x.replyTo === "laptop:w3:9") && d.decisions.length === 5 ? 0 : 1)' "$tmp/devnamed.json" \
  && pass "trick dev --facts: every Decision goes to the session named reviewer" || miss "trick dev --facts: $(head -c 400 "$tmp/devnamed.json")"
RID=0b7e6a1c-2f4d-4e8a-9c3b-5d6e7f8a9b01
cli trick dev "$work" --json --tap yes --node "hill/$K1" --rid $RID --state "$tmp/devstate" > /dev/null 2>&1
cli trick dev "$work" --json --tap yes --node "hill/$K1" --rid $RID --state "$tmp/devstate" > "$tmp/devtap2.json" 2>&1
grep -q 'This tap was recorded already.' "$tmp/devtap2.json" && [ "$(grep -c "\"rid\":\"$RID\"" "$tmp/devstate/given.jsonl")" = 1 ] \
  && pass "trick dev --rid --state: the same rid twice writes one record" || miss "trick dev --rid --state"
rm -rf "$work/media"; : > "$tmp/git.log"

step "timer: five asked, one not asked" "$timer" "$root" "{\"parts\":[\"dashboard\",\"session\"],\"dashboard\":\"Design 5\",\"decisions\":[\"$K1\",\"$K2\",\"$K3\",\"$K4\",\"$K5\"],\"has\":[\"Ship “The sync badge”?\",\"Not asked\",\"no shot: status-item.png\",\"Waiting\"],\"replyTo\":{\"$K1\":\"laptop:w7:2\"},\"media\":{\"$K1\":1,\"$K5\":2},\"captions\":{\"$K1\":\"After\",\"$K5\":\"After,Before\"},\"view\":{\"$K5\":[\"Branch\",\"feat/example\",\"Session\",\"feature worker\",\"http://laptop:8788/settings/sync\"],\"$K1\":[\"Where\",\"Header, the sync badge\"]},\"links\":{\"$K1\":null,\"$K5\":null},\"recommends\":{\"$K1\":null},\"texts\":{\"$K1\":\"optional\",\"$K2\":\"optional\",\"$K3\":\"optional\",\"$K4\":\"optional\",\"$K5\":\"optional\"}}"
grep -q "doctor: not asked, feat/example: The status item: no shot" "$tmp/stderr" || miss "the refused change has no doctor line"
ls "$work/media" | grep -q "^$K1-[0-9a-f]\{12\}\.png$" || miss "no media copy for $K1"
# Two shots draw as before and after (media 1 is the before shot, 0 the new one); one shot gets no compare.
printf '%s' "$out" | K1="$K1" K5="$K5" "$BUN" -e '
const d = JSON.parse(await Bun.stdin.text());
const view = (k) => d.decisions.find((x) => x.key === k).view;
const pair = view(process.env.K5)[0];
const ok = pair.kind === "compare" && pair.kids.map((i) => i.attrs.ref).join() === "1,0" && !JSON.stringify(view(process.env.K1)).includes("compare");
process.exit(ok ? 0 : 1);' && pass "two shots: a before and after compare, one shot: none" || miss "the before and after compare is not as wanted"
first=$(calls)
[ "$first" -gt 0 ] || miss "the first run called git zero times"

step "cache: a second run inside 60 s" "$timer" "$root" '{"dashboard":"Design 5"}'
[ "$(calls)" = "$first" ] && pass "the second run called git 0 times (first run: $first)" || miss "the second run called git $(($(calls) - first)) times"
step "cache: a run after 61 s reads again" "$timer" "$root" '{"dashboard":"Design 5"}' TRICK_NOW=$((NOW + 61))
[ "$(calls)" -gt "$first" ] || miss "a run after 61 s did not read git again"

# Where the count shows is the setting `show`: dashboard (the default), tabbar, status, belt; unknown words are a warn row.
uaconfig 'show = ["status"]\n'
step "show status: a status chip, no tile" "$timer" "$root" '{"parts":["status","session"],"status":"design 5","dashboard":null,"belt":null}'
uaconfig 'show = ["belt", "tabbar"]\n'
step "show belt and tabbar: a Belt mark and a bar item" "$timer" "$root" '{"parts":["tabbar","belt","session"],"belt":"design 5","tabbar":"Design 5","status":null}'
uaconfig 'show = []\n'
step "show []: no part but the session" "$timer" "$root" '{"parts":["session"],"lacks":["which this trick ignores"]}'
uaconfig 'show = ["dashboard", "sparkle"]\n'
step "an unknown word is ignored with one warn row" "$timer" "$root" '{"parts":["dashboard","session"],"has":["show names \"sparkle\", which this trick ignores"]}'
uaconfig 'mark = "belt"\n'
step "the old mark key: the default places and a warn row" "$timer" "$root" '{"parts":["dashboard","session"],"has":["mark is gone: write show = [\"dashboard\"] instead"]}'
uaconfig ''

step "no session in the root and none named: no replyTo, one muted row" "$timer" "/home/dev/other" "{\"replyTo\":{\"$K1\":null,\"$K5\":null},\"view\":{\"$K1\":[\"none\"]},\"has\":[\"answers are recorded here only\",\"and no session is named reviewer\",\"5 of 5 have no one to tell\"]}"
export EXTRA=$DECOYS
step "names that differ by case or a suffix do not match" "$timer" "/home/dev/other" "{\"replyTo\":{\"$K1\":null},\"has\":[\"answers are recorded here only\"]}"
export EXTRA=$NAMED
step "no folder match: the session named reviewer gets replyTo, unchanged" "$timer" "/home/dev/other" "{\"replyTo\":{\"$K1\":\"laptop:w3:9\",\"$K5\":\"laptop:w3:9\"},\"view\":{\"$K1\":[\"reviewer\"]},\"lacks\":[\"answers are recorded here only\"]}"
step "a folder match wins over the name" "$timer" "$root" "{\"replyTo\":{\"$K1\":\"laptop:w7:2\"},\"lacks\":[\"answers are recorded here only\"]}"
unset EXTRA

# The worker's advice: an optional last field `suggest yes|no|change: <why>` in a LOOK.md line. A good one becomes the
# Decision's recommends, with the worker named in the why; a malformed one is ignored with one warn row and the change
# is still asked; a line without the field has no recommends. Run on a copy of LOOK.md and a state folder of its own.
cp "$root/LOOK.md" "$tmp/LOOK.md.keep"
long=$(head -c 201 /dev/zero | tr '\0' 'x')
{
  printf -- '- Suggest yes | /s1 | A suggested change. | badge.png | | suggest yes: The shot matches the sentence.\n'
  printf -- '- Suggest change | /s2 | A second change. | badge.png | settings-sync.png | suggest change: The button sits too close to the edge.\n'
  printf -- '- Suggest no | /s3 | A third change. | badge.png | suggest no: It hides the status row.\n'
  printf -- '- Suggest maybe | /s4 | A fourth change. | badge.png | suggest maybe: I am not sure.\n'
  printf -- '- Suggest long | /s5 | A fifth change. | badge.png | suggest yes: %s\n' "$long"
  printf -- '- Suggest upper | /s6 | A sixth change. | badge.png | Suggest yes: Capital letters are not the form.\n'
  printf -- '- Suggest bare | /s7 | A seventh change. | badge.png | suggest yes\n'
} >> "$root/LOOK.md"
S1=feat-example-suggest-yes S2=feat-example-suggest-change S3=feat-example-suggest-no S4=feat-example-suggest-maybe S5=feat-example-suggest-long S6=feat-example-suggest-upper S7=feat-example-suggest-bare
export STATE=$tmp/state3
step "suggest: a good field becomes recommends, the worker named from the session at the root" "$timer" "$root" "{\"dashboard\":\"Design 12\",\"recommends\":{\"$S1\":\"yes\",\"$S2\":\"change\",\"$S3\":\"no\",\"$S4\":null,\"$S5\":null,\"$S6\":null,\"$S7\":null,\"$K1\":null,\"$K2\":null,\"$K3\":null,\"$K4\":null,\"$K5\":null},\"has\":[\"From feature worker: The shot matches the sentence.\",\"From feature worker: The button sits too close to the edge.\",\"From feature worker: It hides the status row.\"],\"lacks\":[\"Design Review suggests\",\"From feature worker: I am not sure.\"],\"media\":{\"$S1\":1,\"$S2\":2,\"$S3\":1},\"captions\":{\"$S2\":\"After,Before\"},\"texts\":{\"$S1\":\"optional\",\"$S4\":\"optional\"},\"titleEnds\":{\"$S4\":\"Suggest maybe”?\"}}"
printf '%s' "$out" | "$BUN" -e '
const d = JSON.parse(await Bun.stdin.text());
const rows = JSON.stringify(d.parts.find((p) => p.at === "session").view);
const warns = (rows.match(/suggest field not understood \(/g) ?? []).length;
const r = (k) => d.decisions.find((x) => x.key === k);
const ok = warns === 4 && ["feat-example-suggest-maybe", "feat-example-suggest-long", "feat-example-suggest-upper", "feat-example-suggest-bare"].every((k) => r(k) !== undefined && r(k).recommends === undefined)
  && ["yes", "no", "change"].join() === r("feat-example-suggest-yes").options.map((o) => o.intent).sort((a, b) => ["yes", "no", "change"].indexOf(a) - ["yes", "no", "change"].indexOf(b)).join()
  && r("feat-example-suggest-yes").recommends.why.length <= 200 && !rows.includes("suggest field not understood (Suggest yes)");
if (!ok) { console.error("suggest warn rows " + warns); process.exit(1); }' && pass "suggest: four malformed fields are four warn rows, each change is still asked with no recommends" || miss "suggest: the warn rows"
grep -c "doctor: suggest field not understood, feat/example: Suggest maybe" "$tmp/stderr" | grep -q 1 || miss "no doctor line for the malformed suggest field"
step "suggest: no session at the root, the branch's worker" "$timer" "/home/dev/other" "{\"recommends\":{\"$S1\":\"yes\",\"$S3\":\"no\",\"$S4\":null,\"$K1\":null},\"has\":[\"From the branch's worker: The shot matches the sentence.\",\"From the branch's worker: It hides the status row.\"],\"lacks\":[\"From feature worker\"]}"
# A session named reviewer (reply_session) is not known to be the worker: the generic words stay.
EXTRA=$NAMED step "suggest: a reply_session is not the worker" "$timer" "/home/dev/other" "{\"recommends\":{\"$S1\":\"yes\"},\"has\":[\"From the branch's worker: The shot matches the sentence.\"],\"lacks\":[\"From reviewer\"]}"
# A changed suggest gives the Decision new content: the hash of the line changes, and so does the advice.
was=$(grep -o "\"$S1\":\"[0-9a-f]*\"" "$tmp/state3/offered.json")
sed -i 's/suggest yes: The shot matches the sentence\./suggest no: The shot shows the old look./' "$root/LOOK.md"
step "suggest: a changed field is new content" "$timer" "$root" "{\"recommends\":{\"$S1\":\"no\"},\"has\":[\"From feature worker: The shot shows the old look.\"],\"lacks\":[\"The shot matches the sentence.\"]}"
now_hash=$(grep -o "\"$S1\":\"[0-9a-f]*\"" "$tmp/state3/offered.json")
[ -n "$was" ] && [ "$was" != "$now_hash" ] && pass "suggest: the hash of the line changed with the advice, so a yes for the old advice is asked again" || miss "suggest: the hash did not change ($was, $now_hash)"
unset STATE
cp "$tmp/LOOK.md.keep" "$root/LOOK.md"
# The platform's own parser takes the advice: trick dev on a LOOK.md with a good field (recommends printed).
cp "$root/LOOK.md" "$tmp/LOOK.md.keep"
printf -- '- Suggest yes | /s1 | A suggested change. | badge.png | | suggest yes: The shot matches the sentence.\n' >> "$root/LOOK.md"
cli trick dev "$work" --json --state "$tmp/devstate3" > "$tmp/devsuggest.json" 2>&1
"$BUN" -e 'const d = JSON.parse(await Bun.file(process.argv[1]).text()); const r = d.decisions.find((x) => x.key === "feat-example-suggest-yes"); process.exit(d.refusals.length === 0 && r?.recommends?.intent === "yes" && /^From .+: The shot matches the sentence\.$/.test(r.recommends.why) ? 0 : 1)' "$tmp/devsuggest.json" \
  && pass "trick dev --json: the Decision carries recommends, no refusal" || miss "trick dev --json recommends: $(head -c 400 "$tmp/devsuggest.json")"
cp "$tmp/LOOK.md.keep" "$root/LOOK.md"
rm -rf "$work/media"

yes="{\"kind\":\"tap\",\"rid\":\"r-yes-1\",\"node\":\"hill/$K1\",\"intent\":\"yes\",\"value\":{\"text\":null},\"from\":{\"session\":\"laptop:w7:2\"},\"seen\":\"944a71314b332828\"}"
step "tap yes" "$yes" "$root" "{\"dashboard\":\"Design 4\",\"decisions\":[\"$K2\",\"$K3\",\"$K4\",\"$K5\"],\"has\":[\"Given\",\"yes, 2026-11-09\",\"yes given for The sync badge.\"]}"
step "the same rid again" "$yes" "$root" '{"dashboard":"Design 4","has":["This tap was recorded already."]}'
[ "$(grep -c '"rid":"r-yes-1"' "$tmp/state/given.jsonl")" = 1 ] && pass "a repeated rid writes one record" || miss "a repeated rid wrote twice"

change="{\"kind\":\"tap\",\"rid\":\"r-change-1\",\"node\":\"hill/$K3\",\"intent\":\"change\",\"value\":{\"text\":\"Put the switch first in the row.\"}}"
step "tap change with words" "$change" "$root" "{\"dashboard\":\"Design 3\",\"decisions\":[\"$K2\",\"$K4\",\"$K5\"],\"has\":[\"change, 2026-11-09\",\"Put the switch first in the row.\"]}"
step "timer after two answers" "$timer" "$root" "{\"dashboard\":\"Design 3\",\"decisions\":[\"$K2\",\"$K4\",\"$K5\"],\"has\":[\"Given\"]}"
grep -q '"answer":"change","text":"Put the switch first in the row."' "$tmp/state/given.jsonl" || miss "given.jsonl lacks the change words"
grep '"rid":"r-yes-1"' "$tmp/state/given.jsonl" | grep -q '"seen":"944a71314b332828"' || miss "the yes record lacks seen"
grep '"rid":"r-change-1"' "$tmp/state/given.jsonl" | grep -q '"seen":null' || miss "a tap with no seen is not recorded as null"
grep '"rid":"r-yes-1"' "$tmp/state/given.jsonl" | grep -q '"hash":"[0-9a-f]\{12\}"' || miss "the yes record lacks the guard hash"

# A dismiss: a record with seen, the key closed for 24 h, no answer. Run on a copy of the state, then restore it.
cp -r "$tmp/state" "$tmp/state.keep"
dismiss="{\"kind\":\"tap\",\"rid\":\"r-dis-1\",\"node\":\"hill/$K2\",\"intent\":\"dismiss\",\"value\":{\"text\":null},\"seen\":\"aaaa111122223333\"}"
step "tap dismiss: closed for 24 h, nothing given" "$dismiss" "$root" "{\"dashboard\":\"Design 2\",\"decisions\":[\"$K4\",\"$K5\"],\"has\":[\"Dismissed The detail screen, closed for 24 h.\",\"Dismissed: The detail screen, closed until 2026-11-10\"],\"lacks\":[\"no longer listed\"]}"
step "the same dismiss rid again" "$dismiss" "$root" '{"has":["This tap was recorded already."]}'
[ "$(grep -c '"rid":"r-dis-1"' "$tmp/state/dismissed.jsonl")" = 1 ] || miss "a repeated dismiss wrote twice"
grep -q '"key":"'$K2'".*"seen":"aaaa111122223333"' "$tmp/state/dismissed.jsonl" || miss "the dismiss record lacks seen"
grep -q "$K2" "$tmp/state/given.jsonl" && miss "a dismiss wrote an answer"
step "still closed after 23 h" "$timer" "$root" "{\"decisions\":[\"$K4\",\"$K5\"]}" TRICK_NOW=$((NOW + 82800))
step "after 24 h the key is listed again (the re-ask)" "$timer" "$root" "{\"decisions\":[\"$K2\",\"$K4\",\"$K5\"],\"lacks\":[\"Dismissed:\"]}" TRICK_NOW=$((NOW + 86500))
rm -rf "$tmp/state" && mv "$tmp/state.keep" "$tmp/state"

# Answers live only in the state folder: the root is byte for byte the same.
after=$(cd "$root" && find . -type f | sort | xargs md5sum)
[ "$before" = "$after" ] && pass "the branch root is unchanged" || miss "the program wrote into the branch root"

# A changed line asks again: the yes was for the old sentence.
sed -i 's/in its own frame\./in its own frame, now wider./' "$root/LOOK.md"
step "a changed line asks again" "$timer" "$root" "{\"dashboard\":\"Design 4\",\"decisions\":[\"$K1\",\"$K2\",\"$K4\",\"$K5\"]}"
# A changed shot asks again: the change answer was for the old picture.
printf 'x' >> "$root/.look/settings-sync.png"
step "a changed shot asks again" "$timer" "$root" "{\"dashboard\":\"Design 5\",\"decisions\":[\"$K1\",\"$K2\",\"$K3\",\"$K4\",\"$K5\"]}"

# Shots over the caps are not posted: warn rows with the reason.
head -c 8 "$root/.look/badge.png" > "$root/.look/big.png" && head -c 2200000 /dev/zero >> "$root/.look/big.png"
head -c 8 "$root/.look/badge.png" > "$root/.look/mid.png" && head -c 600000 /dev/zero >> "$root/.look/mid.png"
printf -- '- Big shot | /big | Too big. | big.png\n- Mid shot | /mid | Over the cap. | mid.png\n' >> "$root/LOOK.md"
step "shots over 2 MB and 512 KB are warn rows" "$timer" "$root" '{"dashboard":"Design 5","has":["Big shot (feat/example)","over 2 MB","over the 512 KB Design Review takes"],"lacks":["Ship “Big shot”?","Ship “Mid shot”?"]}'

# LOOK.md and .look/ that git would commit: a warn row.
step "not excluded: a warn row" "$timer" "$root" '{"has":["LOOK.md and .look would be committed (feat/example)","info/exclude"]}' FAKE_IGNORED=no TRICK_NOW=$((NOW + 200))

# The mask: a fake key and the home path in a sentence never reach the document.
fake="sk-or-v1-0000000000fakefakefake0000000000"
printf -- '- Leak test | Settings | The key %s must not show, nor %s/secret-folder. | badge.png\n' "$fake" "$HOME" >> "$root/LOOK.md"
step "a key and the home path in LOOK.md are masked" "$timer" "$root" "{\"has\":[\"sk-o****\",\"~/secret-folder\"],\"lacks\":[\"$fake\",\"fakefake\",\"$HOME/secret-folder\"]}"

# git missing: the branch comes from the heading, and a warn row says so.
out=$(facts "$timer" "$root" | (cd "$work" && env PATH="$tmp/nobin" TRICK_TOOLS_ONLY_PATH=1 TRICK_NOW=$((NOW + 400)) "$BUN" ./program.ts) 2>/dev/null)
printf '%s' "$out" | "$BUN" "$tmp/assert.ts" '{"has":["git not found","feat/example"]}' $PLACES && pass "git missing: a warn row" || miss "git missing"

# A broken config.toml: the helper's warn card in the Session, exit 0.
printf 'roots = [\n' > "$work/config.toml"
step "a broken config.toml is a warn card" "$timer" "$root" '{"parts":["session"],"decisions":[],"has":["warn"]}'

# A root with no LOOK.md: no badge, a plain line.
printf 'roots = ["%s/nothing-*"]\n' "$tmp" > "$work/config.toml"
step "no LOOK.md: a tile with no badge" "$timer" "$root" '{"parts":["dashboard","session"],"dashboard":"Design","decisions":[],"has":["No LOOK.md under the roots"]}'

if grep -q '^WRITE' "$tmp/git.log"; then miss "a write verb reached git"; else pass "git saw read verbs only ($(cut -d' ' -f3 "$tmp/git.log" | sort -u | tr '\n' ' '))"; fi

# The program writes only to its state folder and media/: a fresh copy, listed before and after a timer run,
# a yes, the same yes again and a dismiss.
clean=$tmp/clean
cp -r "$here" "$clean" && rm -rf "$clean/media"
printf 'roots = ["%s/fixtures/*"]\nreply_session = "reviewer"\n' "$clean" > "$clean/config.toml"
list() { (cd "$clean" && find . -path ./media -prune -o -type f -print | sort | xargs md5sum); }
was=$(list)
export DIR=$clean STATE=$tmp/state2
step "fresh copy: timer" "$timer" "$clean/fixtures/feat-example" "{\"decisions\":[\"$K1\",\"$K2\",\"$K3\",\"$K4\",\"$K5\"]}"
step "fresh copy: yes" "$yes" "$clean/fixtures/feat-example" '{"dashboard":"Design 4"}'
step "fresh copy: the same yes" "$yes" "$clean/fixtures/feat-example" '{"has":["This tap was recorded already."]}'
step "fresh copy: dismiss" "$dismiss" "$clean/fixtures/feat-example" '{"dashboard":"Design 3"}'
unset DIR STATE
[ "$was" = "$(list)" ] && pass "outside media/ the trick folder is unchanged" || miss "the program wrote into its own folder outside media/"
[ "$(ls "$tmp/state2" | sort | tr '\n' ' ')" = "cache-git-feat-example-$(ls "$tmp/state2" | sed -n 's/^cache-git-feat-example-//p' | head -1) closed.json dismissed.jsonl given.jsonl offered.json " ] && pass "the state folder holds the cache, closed, dismissed, given and offered" || miss "state folder: $(ls "$tmp/state2" | tr '\n' ' ')"
[ "$(grep -c '"rid":"r-yes-1"' "$tmp/state2/given.jsonl")" = 1 ] && pass "fresh copy: one record for one rid" || miss "fresh copy: the rid wrote twice"

[ "$failed" = 0 ] && echo "all ok" || { echo "FAILED"; exit 1; }
