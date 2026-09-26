#!/bin/zsh
# tools/mac-xctest-run.sh <worktree> <out-prefix> [-only-testing X ...]
# Runs the mac Swift tests of an already `zig build`-built worktree, isolated
# from the user's session, and prints test counts per suite.
#
# Measured 2026-09-27 on 9ba688d4d: the counts reproduce the known baseline
# (ProjectDocumentTests 7, ProjectStoreTests 7, TerminalRestorableTests 3).
#
# - build-for-testing and test-without-building are separate so the host's
#   bundle id can be checked in between (Debug => com.lugia.polter.debug).
# - The test host gets no command-line flags, so MCP registration is turned off
#   by a config file: TEST_RUNNER_XDG_CONFIG_HOME -> <tmp>/config/polter/config.polter.
#   **That file was never read** (measured 2026-09-27): the test plan
#   (macos/Ghostty.xctestplan) sets GHOSTTY_CONFIG_PATH to
#   /tmp/Ghostty/testing_config.ghostty, which normally does not exist, so
#   the host loaded no config at all -- host log `error loading config from
#   file path=/tmp/Ghostty/testing_config.ghostty err=error.FileNotFound` and
#   no `reading configuration file` line. The register-mcp=false above never
#   took effect. TEST_RUNNER_GHOSTTY_CONFIG_PATH overrides the plan's value
#   with the file above; the host then loads exactly that file (one
#   `reading configuration file` line) and register-mcp=false is in force.
#   The user's config is not read either way.
#   TEST_RUNNER_XDG_STATE_HOME puts its socket/state under /tmp (short path).
# - `-skip-testing GhosttyUITests` must be given to the *test* step too: the
#   xctestrun carries the UI tests, and running them pops a system
#   "XCTest wants to Enable UI Automation" password dialog on the user's screen.
# - DerivedData lives inside the worktree, so removing the worktree removes it.
# - **Zero tests run is a failure, not a pass.** `-only-testing` that matches
#   nothing makes xcodebuild run no tests and exit 0 -- indistinguishable from
#   "all passed" unless something counts. Measured 2026-09-27 on 684cadade,
#   issue #28, a test that had to be red before its fix:
#     -only-testing:GhosttyTests/PluginSettingsTests/severalSubscriptionsGiveSeveralPhrases
#       -> xcodebuild exit=0, TOTAL 0   (nothing ran; read as green)
#     -only-testing:GhosttyTests/PluginSettingsTests/severalSubscriptionsGiveSeveralPhrases()
#       -> xcodebuild exit=65, TOTAL 1, Failed 1   (the real reading)
#   A Swift Testing `@Test` is named with its `()`. So TOTAL 0 exits 3 here,
#   after cleaning up, and says why. Same shape as `zig build test
#   -Dtest-filter` matching nothing: a filter that matches nothing does not
#   fail, it quietly tests nothing.
# - **The user's MCP registration changing fails the run (exit 4).** This check
#   is the one gate left from #832 ("mac GUI tests leak into the user's
#   session"): a test host that registers itself rewrites mcpServers.polter
#   in the user's ~/.claude.json, and the user's polter MCP then points at a
#   build that is about to be deleted. It used to print a line and exit 0, so
#   a scripted run reported success while the user's setup was broken. Now it
#   cleans up, prints what the entry was and what it became, and the exact
#   command that puts it back, then exits 4 (3 is "no tests ran").
#   MAC_XCTEST_CLAUDE_JSON overrides the file watched -- it exists so the
#   floor for this check can change a copy instead of the user's own file.
set -eu
wt=$1; out=$2; shift 2
die() { print -u2 "xctest-run: $*"; exit 1; }
[ -d "$wt/macos" ] || die "no macos/ in $wt"

claude_json=${MAC_XCTEST_CLAUDE_JSON:-$HOME/.claude.json}
mcp() { python3 -c "import json,sys;d=json.load(open(sys.argv[1]));o=d.get('mcpServers',{}).get('polter');print('EXISTS' if o else 'ABSENT');print(json.dumps(o,sort_keys=True))" "$claude_json"; }
before=$(mcp); [[ $before == EXISTS* ]] || die "mcpServers.polter is absent from $claude_json: the before/after check could not fail, refusing"
# The entry exactly as it was, as a file the restore command below can read.
python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))['mcpServers']['polter'],indent=2))" "$claude_json" > "$out-mcp-before.json"

cd "$wt/macos"
env -i PATH="$PATH" HOME="$HOME" xcodebuild build-for-testing -scheme Ghostty -skip-testing GhosttyUITests \
    -derivedDataPath "$wt/dd" > "$out-bft.log" 2>&1 || die "build-for-testing failed, see $out-bft.log"
app="$wt/dd/Build/Products/Debug/Polter.app"
bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
inst=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' /Applications/Polter.app/Contents/Info.plist 2>/dev/null || true)
[[ $bid != com.lugia.polter && $bid != $inst && -n $bid ]] || die "test host bundle id '$bid' is the user's; refusing"
xtr=$(ls "$wt"/dd/Build/Products/*.xctestrun | head -1)

x=$(mktemp -d /tmp/pxt.XXXX); mkdir -p "$x/config/polter" "$x/state"
print 'poltergeist-register-mcp = false' > "$x/config/polter/config.polter"
env -i PATH="$PATH" HOME="$HOME" TEST_RUNNER_XDG_CONFIG_HOME="$x/config" TEST_RUNNER_XDG_STATE_HOME="$x/state" \
    TEST_RUNNER_GHOSTTY_CONFIG_PATH="$x/config/polter/config.polter" \
    xcodebuild test-without-building -xctestrun "$xtr" -destination 'platform=macOS,arch=arm64' \
    -skip-testing GhosttyUITests "$@" -resultBundlePath "$out.xcresult" > "$out-test.log" 2>&1 && rc=0 || rc=$?
print "xcodebuild test exit=$rc; host state used: $(ls $x/state/polter 2>/dev/null | tr '\n' ' ')"

after=$(mcp) || after="UNREADABLE (the file no longer parses as JSON)"
if [[ $after == $before ]]; then print MCP_SAME; mcp_changed=0; else mcp_changed=1; fi
xcrun xcresulttool get test-results tests --path "$out.xcresult" > "$out.json"
python3 - "$out.json" <<'EOF' && counted=0 || counted=$?
import json, sys
from collections import Counter, defaultdict
d = json.load(open(sys.argv[1])); per = defaultdict(Counter); fails = []
def walk(n, suite):
    t = n.get('nodeType')
    if t == 'Test Case':
        per[suite][n.get('result')] += 1
        if n.get('result') == 'Failed':
            fails.append(suite + ' / ' + n.get('name', '') + ' | ' + ' || '.join((c.get('name') or '')[:200] for c in n.get('children', [])))
        return
    for c in n.get('children', []): walk(c, n.get('name') if t == 'Test Suite' else suite)
for n in d.get('testNodes', []): walk(n, '?')
for s in sorted(per): print(sum(per[s].values()), s, dict(per[s]))
total = sum(sum(c.values()) for c in per.values())
print('TOTAL', total)
for f in fails: print('FAIL', f)
sys.exit(3 if total == 0 else 0)
EOF
rm -rf "$x" "$out.xcresult"
if [ "$mcp_changed" -eq 1 ]; then
    print -u2 "xctest-run: the user's MCP registration CHANGED during this run -- key mcpServers.polter in $claude_json."
    print -u2 "  was: ${before#EXISTS$'\n'}"
    print -u2 "  now: ${after#EXISTS$'\n'}"
    print -u2 "  The user's polter MCP may now point at this test build. Put the old entry back, changing only that key (other sessions write this file, so do not overwrite it whole):"
    print -u2 "  python3 -c \"import json,os,sys;p=sys.argv[1];d=json.load(open(p));d.setdefault('mcpServers',{})['polter']=json.load(open(sys.argv[2]));t=p+'.xctest-restore';json.dump(d,open(t,'w'),indent=2,ensure_ascii=False);os.replace(t,p)\" '$claude_json' '$out-mcp-before.json'"
    print -u2 "  Then compare mcpServers.polter with $out-mcp-before.json once more."
    [ "$counted" -eq 3 ] && print -u2 "xctest-run: also, 0 tests ran (see exit 3 in the header)."
    exit 4
fi
if [ "$counted" -eq 3 ]; then
    print -u2 "xctest-run: 0 tests ran (xcodebuild exit=$rc). This is not a pass: the -only-testing filter matched nothing. A Swift Testing @Test is named with its (), e.g. -only-testing:GhosttyTests/PluginSettingsTests/severalSubscriptionsGiveSeveralPhrases()"
    exit 3
fi
[ "$counted" -eq 0 ] || die "counting the results failed (exit $counted)"
