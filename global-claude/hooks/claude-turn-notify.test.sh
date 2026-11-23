#!/bin/bash
# Behaviour tests for claude-turn-notify.sh
#
# The hook decides whether a finished turn is something the captain needs to
# know about. Getting it wrong is silent by nature - a suppressed alert leaves
# no trace he would notice until he is already waiting on a terminal that never
# called him back, and an over-eager one trains him to ignore the banners. Both
# failures have happened in production. These tests pin the decision for every
# case the design depends on, including the ones each previous version broke.
#
# Each test runs the real script inside a throwaway HOME, with stub `tmux` and
# `firstmate-notify` binaries, so nothing here touches live state or delivers a
# real notification.
#
# The origin tests are deliberately NOT mocked. The script decides who fired it
# by walking the real process table, so these build a real process tree with the
# shape being tested - a pane-level session, or one nested under a tool - and
# let the script read it. A mock here would only prove the mock agrees with
# itself, which is exactly how the previous version passed its own tests while
# flooding the captain.
#
#   ./claude-turn-notify.test.sh [path-to-script]

set -u

SCRIPT="${1:-$HOME/.claude/hooks/claude-turn-notify.sh}"
JUMP="${2:-$HOME/.local/bin/claude-session-jump}"
PASS=0
FAIL=0

if [ ! -x "$SCRIPT" ]; then
  printf 'cannot run: %s is not executable\n' "$SCRIPT" >&2
  exit 2
fi

# The pane's shell, as far as every test is concerned, is this test process.
# A hook invoked directly from here therefore terminates its walk at the pane
# boundary without finding a session, which is the inconclusive case - so the
# plain `run` helper exercises fail-open behaviour, and the two origin helpers
# below build an explicit session layer when that is what is under test.
TEST_PID=$$

SANDBOX=""

setup() {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.claude/hooks" "$SANDBOX/.local/bin" "$SANDBOX/bin"

  # Stub tmux: answers the pane-pid query with the tree the test built, and
  # anything else with the declared session name.
  cat >"$SANDBOX/bin/tmux" <<'STUB'
#!/bin/bash
for a in "$@"; do
  case "$a" in
    *pane_pid*) printf '%s\n' "${FAKE_PANE_PID:-0}"; exit 0 ;;
    *client_tty*)
      [ -f "$HOME/pane-tty" ] && printf '%s %s\n' "$(cat "$HOME/pane-tty")" "${FAKE_SESSION:-testsession}"
      exit 0 ;;
  esac
done
printf '%s\n' "${FAKE_SESSION:-testsession}"
STUB
  chmod +x "$SANDBOX/bin/tmux"

  # Stub notifier: records the call instead of delivering anything.
  cat >"$SANDBOX/.local/bin/firstmate-notify" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$SANDBOX_CALLS"
exit 0
STUB
  chmod +x "$SANDBOX/.local/bin/firstmate-notify"

  # Runs the hook as a child, so whatever argv[0] this shim was launched under
  # stays in the process table as the hook's parent.
  cat >"$SANDBOX/bin/shim" <<'STUB'
#!/bin/bash
"$HOOK_UNDER_TEST"
STUB
  chmod +x "$SANDBOX/bin/shim"

  # A tool layer: a non-session process that spawns a session beneath itself,
  # reproducing `node pipeline.js` launching `claude -p`.
  cat >"$SANDBOX/bin/toolshim" <<'STUB'
#!/bin/bash
( exec -a claude bash "$SHIM" )
STUB
  chmod +x "$SANDBOX/bin/toolshim"

  # Stub terminal: reports one pane on the tty the test session was given, and
  # records which pane a click activates.
  cat >"$SANDBOX/bin/wezterm" <<'STUB'
#!/bin/bash
case "$*" in
  *"list-clients"*) printf '[{"focused_pane_id":7}]\n' ;;
  *"list"*)
    # Another window, then: two tabs (one split), and the session's tab third.
    # Tab ids are out of order, as they are once tabs have been moved.
    printf '[{"window_id":1,"tab_id":2,"pane_id":1},{"window_id":0,"tab_id":9,"pane_id":3},{"window_id":0,"tab_id":4,"pane_id":4},{"window_id":0,"tab_id":4,"pane_id":5},'
    printf '{"window_id":0,"tab_id":1,"pane_id":7,"tty_name":"%s","title":"%s","tab_title":"%s"}]\n' \
      "$(cat "$HOME/pane-tty" 2>/dev/null)" "$(cat "$HOME/pane-title" 2>/dev/null)" "$(cat "$HOME/tab-name" 2>/dev/null)" ;;
  *"activate-pane"*) printf '%s\n' "$*" >>"$HOME/activated" ;;
esac
STUB
  printf '#!/bin/bash\nexit 0\n' >"$SANDBOX/bin/open"
  chmod +x "$SANDBOX/bin/wezterm" "$SANDBOX/bin/open"

  # A session in a plain terminal: its own tty, and no Claude process above it.
  # The test runner may itself live under Claude, so the tree is detached first.
  cat >"$SANDBOX/bin/plain.py" <<'STUB'
import os, pty, sys, time
r, w = os.pipe()
if os.fork() == 0:
    os.close(r)
    if os.fork():
        os._exit(0)
    while os.getppid() != 1:
        time.sleep(0.02)
    pid, fd = pty.fork()
    if pid == 0:
        with open(os.environ["HOME"] + "/pane-tty", "w") as f:
            f.write(os.ttyname(0))
        os.dup2(os.open(sys.argv[1], os.O_RDONLY), 0)
        layer = 'exec -a claude bash "$SHIM"'
        if sys.argv[2] == "nested":
            layer = "exec -a claude bash -c '( exec -a claude bash \"$SHIM\" ); :'"
        os.execvp("bash", ["bash", "-c", layer])
    try:
        while os.read(fd, 4096):
            pass
    except OSError:
        pass
    os.waitpid(pid, 0)
    os._exit(0)
os.close(w)
os.wait()
os.read(r, 1)
STUB

  : >"$SANDBOX/calls"
}

teardown() {
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  SANDBOX=""
}

hook_env() {
  printf '%s\n' \
    "HOME=$SANDBOX" \
    "PATH=$SANDBOX/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
    "SANDBOX_CALLS=$SANDBOX/calls" \
    "FAKE_SESSION=${FAKE_SESSION:-testsession}" \
    "FAKE_PANE_PID=$TEST_PID" \
    "TMUX=${FAKE_TMUX-/tmp/fake-tmux,1,0}" \
    "TMUX_PANE=${FAKE_TMUX_PANE-%1}" \
    "CLAUDE_CODE_ENTRYPOINT=${FAKE_ENTRY-cli}" \
    "WEZTERM_PANE=" \
    "SETTLE_SECONDS=${SETTLE_SECONDS:-0}" \
    "CONFIRM_SECONDS=${CONFIRM_SECONDS:-0}" \
    "HOOK_UNDER_TEST=$SCRIPT" \
    "SHIM=$SANDBOX/bin/shim" \
    "FAILURE_COOLDOWN_SECONDS=${FAILURE_COOLDOWN_SECONDS:-300}" \
    "DISABLE_MAX_AGE_SECONDS=${DISABLE_MAX_AGE_SECONDS:-86400}"
}

# run <json> - origin inconclusive (no session layer); must fail open.
run() {
  local e; e="$(hook_env)"
  # shellcheck disable=SC2046
  printf '%s' "$1" | env $(printf '%s ' $e) "$SCRIPT" >/dev/null 2>&1
}

# run_interactive <json> - the session IS the pane's foreground process.
run_interactive() {
  local e; e="$(hook_env)"
  # shellcheck disable=SC2046
  # `exec` replaces this pipeline element, so the session layer sits directly
  # under the pane shell exactly as a real interactive session does.
  printf '%s' "$1" | env $(printf '%s ' $e) bash -c 'exec -a claude bash "$SHIM"' >/dev/null 2>&1
}

# run_programmatic <json> - the session sits below a tool, as a pipeline's
# `claude -p` child does.
run_programmatic() {
  local e; e="$(hook_env)"
  # shellcheck disable=SC2046
  printf '%s' "$1" | env $(printf '%s ' $e) bash -c 'exec -a node bash "$SANDBOX_TOOLSHIM"' >/dev/null 2>&1
}

# run_plain <json> [nested] - a session in a terminal tab with no tmux.
run_plain() {
  local e; e="$(FAKE_TMUX='' FAKE_TMUX_PANE='' hook_env)"
  printf '%s' "$1" >"$SANDBOX/input"
  # shellcheck disable=SC2046
  env $(printf '%s ' $e) python3 -I "$SANDBOX/bin/plain.py" "$SANDBOX/input" "${2:-direct}" >/dev/null 2>&1
}

# work_json <sid> <prompt_id> <background_tasks> [session_crons]
work_json() {
  printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"%s","cwd":"/tmp/project","last_assistant_message":"done","background_tasks":%s,"session_crons":%s}' \
    "$1" "$2" "$3" "${4:-[]}"
}

# task <type> [command]
task() {
  jq -cn --arg t "$1" --arg c "${2:-}" '[{id:"t1",type:$t,status:"running",description:"x"} + (if $c == "" then {} else {command:$c} end)]'
}

wake_json() { prompt_json "$1" "$2" '<task-notification>job finished'; }

check_lacks() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$SANDBOX/calls" 2>/dev/null; then
    FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$desc"
  else
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$desc"
  fi
}

calls() { wc -l <"$SANDBOX/calls" | tr -d ' '; }

prompt_json() {
  # prompt_json <sid> <prompt_id> [prompt-text]
  local text="${3:-do the thing}"
  printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","prompt_id":"%s","cwd":"/tmp/p","prompt":%s}' \
    "$1" "$2" "$(printf '%s' "$text" | jq -Rs .)"
}

stop_json() {
  # stop_json <sid> <prompt_id>
  printf '{"hook_event_name":"Stop","session_id":"%s","prompt_id":"%s","cwd":"/tmp/p","last_assistant_message":"done"}' \
    "$1" "$2"
}

check() {
  local desc="$1" want="$2" got
  got="$(calls)"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s (expected %s notification(s), got %s)\n' "$desc" "$want" "$got"
    sed 's/^/         log: /' "$SANDBOX/.claude/hooks/turn-notify.log" 2>/dev/null | tail -4
  fi
}

check_contains() {
  local desc="$1" needle="$2"
  if grep -qF -- "$needle" "$SANDBOX/calls" 2>/dev/null; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$desc"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s (no call containing %s)\n' "$desc" "$needle"
  fi
}

printf 'claude-turn-notify behaviour\n'

# --- The core promise -------------------------------------------------------

setup
run "$(prompt_json s1 p1)"
run "$(stop_json s1 p1)"
check "captain prompt then quiet turn end alerts" 1
teardown

setup
run "$(prompt_json s2 p2)"
run "$(stop_json s2 p2)"
run "$(stop_json s2 p2)"
check "one captain prompt yields exactly one alert" 1
teardown

setup
run "$(prompt_json s3 p3a)"
run "$(stop_json s3 p3a)"
: >"$SANDBOX/calls"
run "$(stop_json s3 p3b)"
check "a later turn the captain did not start stays silent" 0
teardown

# --- Turns the machine started, not the captain -----------------------------
#
# A background job finishing wakes its session by submitting a prompt. That is
# the 2026-09-01 flood: one prompt from the captain, an alert per completion.

setup
run "$(prompt_json s4 p4a)"
run "$(stop_json s4 p4a)"
: >"$SANDBOX/calls"
run "$(prompt_json s4 p4 '<task-notification>
<task-id>abc</task-id> job finished')"
run "$(stop_json s4 p4)"
check "a background wake after the prompt was answered stays silent" 0
teardown

setup
run "$(prompt_json s5 p5a)"
run "$(stop_json s5 p5a)"
: >"$SANDBOX/calls"
run "$(prompt_json s5 p5 '[SYSTEM NOTIFICATION - NOT USER INPUT] background event')"
run "$(stop_json s5 p5)"
check "a system wake after the prompt was answered stays silent" 0
teardown

setup
run "$(prompt_json s6 p6)"
run "$(stop_json s6 p6)"
: >"$SANDBOX/calls"
run "$(prompt_json s6 p6a '<task-notification>job finished')"
run "$(stop_json s6 p6a)"
run "$(prompt_json s6 p6b 'now do the next thing')"
run "$(stop_json s6 p6b)"
check "a machine wake does not suppress the captain's next prompt" 1
teardown

setup
run "$(prompt_json s7 p7 'summarise the <task-notification> format for me')"
run "$(stop_json s7 p7)"
check "a human prompt merely mentioning a marker still alerts" 1
teardown

# --- Who fired the hook -----------------------------------------------------
#
# Six of seven alerts in one project on 2026-09-01 came from `claude -p`
# sub-sessions a pipeline spawned inside the captain's tab. They are not
# sessions he is watching, and they can present perfect evidence of a fresh
# human prompt, so they must be excluded by origin rather than by content.

setup
run_interactive "$(prompt_json s8 p8)"
run_interactive "$(stop_json s8 p8)"
check "the pane's own session alerts" 1
teardown

setup
SANDBOX_TOOLSHIM="$SANDBOX/bin/toolshim" \
  run_programmatic "$(prompt_json s9 p9)"
SANDBOX_TOOLSHIM="$SANDBOX/bin/toolshim" \
  run_programmatic "$(stop_json s9 p9)"
check "a session nested under a tool stays silent" 0
teardown

setup
SANDBOX_TOOLSHIM="$SANDBOX/bin/toolshim" \
  run_programmatic "$(prompt_json s10 p10)"
check "a nested session leaves no state behind" 0
if [ -z "$(ls -A "$SANDBOX/.claude/hooks/.turn-notify-state" 2>/dev/null)" ]; then
  PASS=$((PASS + 1)); printf '  ok   nested session writes no markers\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL nested session wrote markers\n'
fi
teardown

setup
SANDBOX_TOOLSHIM="$SANDBOX/bin/toolshim" \
  run_programmatic '{"hook_event_name":"Notification","session_id":"s11","prompt_id":"p11","notification_type":"permission_prompt","message":"needs approval"}'
check "a nested session's permission prompt stays silent" 0
teardown

# --- Failing open -----------------------------------------------------------
#
# Silence is indistinguishable from "still working", so every inconclusive
# reading must alert. This is what kept the sixteen-day August outage invisible.

setup
run "$(stop_json s12 p12)"
check "a turn with no prompt history alerts" 1
teardown

setup
run '{"hook_event_name":"Stop","session_id":"s13","cwd":"/tmp/p"}'
check "a turn with no prompt id alerts" 1
teardown

setup
run "$(prompt_json s14 p14)"
run '{"hook_event_name":"Stop","session_id":"s14","cwd":"/tmp/p"}'
check "a tracked session still alerts when the turn cannot be identified" 1
teardown

# --- Failures ---------------------------------------------------------------

setup
run "$(prompt_json s15 p15)"
run '{"hook_event_name":"StopFailure","session_id":"s15","prompt_id":"p15","cwd":"/tmp/p","stop_reason":"boom"}'
check "a failed turn alerts" 1
check_contains "a failed turn is urgent" "--level urgent"
: >"$SANDBOX/calls"
run "$(stop_json s15 p15)"
check "a failed turn consumes its pending prompt" 0
teardown

setup
run '{"hook_event_name":"StopFailure","session_id":"s16","prompt_id":"p16a","cwd":"/tmp/p"}'
run '{"hook_event_name":"StopFailure","session_id":"s16","prompt_id":"p16b","cwd":"/tmp/p"}'
check "repeated failures are rate limited to one alert" 1
teardown

setup
run '{"hook_event_name":"StopFailure","session_id":"s17","prompt_id":"p17","cwd":"/tmp/p"}'
check "a machine-woken turn that dies still alerts" 1
teardown

# --- Notifications ----------------------------------------------------------

setup
run '{"hook_event_name":"Notification","session_id":"s18","notification_type":"permission_prompt","message":"needs approval"}'
check "a permission prompt alerts" 1
# A muted level here hides every later alert in the Persistent stack.
check_contains "a blocked session is never sent muted" "--level attention"
teardown

setup
run '{"hook_event_name":"Notification","session_id":"s19","notification_type":"idle_prompt","message":"idle"}'
check "an idle prompt stays silent" 0
teardown

setup
run "$(prompt_json s20 p20)"
run '{"hook_event_name":"Notification","session_id":"s20","prompt_id":"p20","notification_type":"permission_prompt","message":"needs approval"}'
: >"$SANDBOX/calls"
run "$(stop_json s20 p20)"
check "a mid-turn notification does not consume the pending prompt" 1
teardown

# --- Global off switch ------------------------------------------------------

setup
: >"$SANDBOX/.claude/hooks/turn-notify-disabled"
run "$(prompt_json s21 p21)"
run "$(stop_json s21 p21)"
run '{"hook_event_name":"StopFailure","session_id":"s21","prompt_id":"p21x","cwd":"/tmp/p"}'
run '{"hook_event_name":"Notification","session_id":"s21","notification_type":"permission_prompt","message":"x"}'
check "the off switch silences every event type" 0
teardown

setup
: >"$SANDBOX/.claude/hooks/turn-notify-disabled"
run "$(prompt_json s22 p22a)"
rm -f "$SANDBOX/.claude/hooks/turn-notify-disabled"
run "$(prompt_json s22 p22b)"
run "$(stop_json s22 p22b)"
check "removing the off switch restores alerting" 1
teardown

# A kill switch left on by a test run silenced the captain for sixteen days in
# August, and nothing surfaced it because a muted notifier looks exactly like a
# quiet fleet. It lapses unless it says it means to persist.

setup
: >"$SANDBOX/.claude/hooks/turn-notify-disabled"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$SANDBOX/.claude/hooks/turn-notify-disabled"
run "$(prompt_json s23 p23)"
run "$(stop_json s23 p23)"
check "a stale off switch expires and alerting resumes" 1
if [ ! -f "$SANDBOX/.claude/hooks/turn-notify-disabled" ]; then
  PASS=$((PASS + 1)); printf '  ok   the expired off switch is cleared\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL the expired off switch survived\n'
fi
teardown

setup
printf 'permanent - captain does not want these\n' >"$SANDBOX/.claude/hooks/turn-notify-disabled"
touch -t "$(date -v-30d +%Y%m%d%H%M)" "$SANDBOX/.claude/hooks/turn-notify-disabled"
run "$(prompt_json s24 p24)"
run "$(stop_json s24 p24)"
check "an off switch marked permanent does not expire" 0
teardown

# --- Scope ------------------------------------------------------------------

setup
run_plain "$(prompt_json s25 p25)"
run_plain "$(work_json s25 p25 '[]')"
check "a plain terminal session alerts" 1
check_contains "its click opens that exact pane" "claudejump://wezterm/7/ttys"
teardown

setup
printf 'Fix the weekly report' >"$SANDBOX/pane-title"
run_plain "$(prompt_json s25b p25b)"
run_plain "$(work_json s25b p25b '[]')"
check_contains "a plain session is named by its tab" "Fix the weekly report"
teardown

setup
run_plain '{"hook_event_name":"Notification","session_id":"s25c","cwd":"/tmp/project","notification_type":"permission_prompt","message":"needs approval"}'
check "a blocked plain session alerts" 1
teardown

setup
run_plain '{"hook_event_name":"StopFailure","session_id":"s25d","cwd":"/tmp/project","error":"rate_limit"}'
check "a failed plain session alerts" 1
teardown

setup
FAKE_ENTRY=sdk-cli run_plain "$(prompt_json s25e p25e)"
FAKE_ENTRY=sdk-cli run_plain "$(work_json s25e p25e '[]')"
check "a scripted session in a plain terminal stays silent" 0
teardown

setup
run_plain "$(work_json s25f p25f '[]')" nested
check "a session started by another session stays silent" 0
teardown

setup
FAKE_TMUX='' FAKE_TMUX_PANE='' run_interactive "$(work_json s25g p25g '[]')"
check "a session with no terminal stays silent" 0
teardown

setup
FAKE_ENTRY=sdk-ts run "$(work_json s25h p25h '[]')"
check "a scripted session stays silent even when ancestry is unresolved" 0
teardown

setup
FAKE_TMUX='' FAKE_TMUX_PANE='' run "$(work_json s25i p25i '[]')"
check "an unresolved session outside tmux fails open" 1
teardown

setup
printf 'project\n' >"$SANDBOX/.claude/hooks/turn-notify-ignore"
run_plain "$(work_json s25j p25j '[]')"
check "the tmux ignore list cannot mute a plain folder of the same name" 1
teardown

setup
printf 'ignoreme\n' >"$SANDBOX/.claude/hooks/turn-notify-ignore"
FAKE_SESSION=ignoreme run "$(prompt_json s26 p26)"
FAKE_SESSION=ignoreme run "$(stop_json s26 p26)"
check "an ignored session stays silent" 0
teardown

# --- Truly done: one alert per prompt, when its work has finished -----------

for kind in shell subagent monitor workflow teammate 'MCP task' 'cloud session'; do
  setup
  run "$(prompt_json d1 a)"
  run "$(work_json d1 a "$(task "$kind" 'make test')")"
  check "waiting on $kind stays silent" 0
  run "$(wake_json d1 b)"
  run "$(work_json d1 b '[]')"
  check "the end of $kind alerts" 1
  teardown
done

setup
run "$(prompt_json d2 a)"
run "$(work_json d2 a "$(task subagent)")"
run "$(wake_json d2 b)"
run "$(work_json d2 b "$(task subagent)")"
check "each partial completion stays silent" 0
run "$(wake_json d2 c)"
run "$(work_json d2 c '[]')"
run "$(wake_json d2 d)"
run "$(work_json d2 d '[]')"
check "a whole chain of work yields exactly one alert" 1
teardown

setup
run "$(work_json d3 a "$(task subagent)")"
check "unknown history still waits for running work" 0
run "$(wake_json d3 b)"
run "$(work_json d3 b '[]')"
check "and alerts when that work ends" 1
teardown

setup
run "$(wake_json d4 a)"
run "$(work_json d4 a '[]')"
check "a wake with unknown history fails open" 1
run "$(wake_json d4 b)"
run "$(work_json d4 b '[]')"
check "but only once" 1
teardown

setup
run "$(prompt_json d5 a)"
run "$(work_json d5 a '[]' '[{"id":"c","schedule":"5 4 22 11 *","recurring":false,"prompt":"check it"}]')"
check "a one-time wake-up holds" 0
run "$(prompt_json d5 b 'check it')"
run "$(work_json d5 b '[]')"
check "the turn after the wake-up alerts" 1
teardown

setup
cron='[{"id":"c","schedule":"*/5 * * * *","recurring":true,"prompt":"poll the queue"}]'
run "$(prompt_json d6 a)"
run "$(work_json d6 a '[]' "$cron")"
check "a repeating loop does not hold" 1
run "$(prompt_json d6 b 'poll the queue')"
run "$(work_json d6 b '[]' "$cron")"
check "each loop tick does not alert again" 1
teardown

for cmd in 'cd app && PORT=3000 npm run dev > /dev/null 2>&1' 'python3 -m http.server 8000' \
  'pnpm --filter web dev' 'next dev' 'tail -f app.log' 'uvicorn app:api --port 8000'; do
  setup
  run "$(prompt_json d7 a)"
  run "$(work_json d7 a "$(task shell "$cmd")")"
  check "a server does not hold: $cmd" 1
  teardown
done

for cmd in 'make test > /dev/null 2>&1' 'gh run watch 123' 'npm run build' 'vite build' \
  'tail -f app.log | grep -m1 ready' 'npm run dev & sleep 5; curl localhost:3000' \
  'npm test -- start' 'until test -f finished; do sleep 2; done'; do
  setup
  run "$(prompt_json d8 a)"
  run "$(work_json d8 a "$(task shell "$cmd")")"
  check "a job holds: $cmd" 0
  teardown
done

for kind in dream 'auto-mode scan' something-new; do
  setup
  run "$(prompt_json d9 a)"
  run "$(work_json d9 a "$(task "$kind")")"
  check "$kind cannot hold an alert forever" 1
  teardown
done

setup
run "$(prompt_json d10 a)"
run '{"hook_event_name":"Stop","session_id":"d10","prompt_id":"a","cwd":"/tmp/p","background_tasks":null,"session_crons":"bad"}'
check "an unreadable work report fails open" 1
teardown

setup
run "$(prompt_json d11 a)"
run '{"hook_event_name":"StopFailure","session_id":"d11","prompt_id":"a","cwd":"/tmp/p","error":"rate_limit"}'
check_contains "a failure gives Claude's reason" "rate_limit"
run "$(wake_json d11 b)"
run "$(work_json d11 b '[]')"
check "background work finishing after a failure still alerts" 2
teardown

setup
run '{"hook_event_name":"StopFailure","session_id":"d12a","cwd":"/tmp/p","error":"overloaded"}'
run '{"hook_event_name":"StopFailure","session_id":"d12b","cwd":"/tmp/p","error":"overloaded"}'
check "two sessions with one name each report their failure" 2
teardown

for kind in computer_use_enter computer_use_exit quota_auto_resume_fired; do
  setup
  run "{\"hook_event_name\":\"Notification\",\"session_id\":\"d13\",\"notification_type\":\"$kind\",\"message\":\"x\"}"
  check "$kind is not a request for input" 0
  teardown
done

# A finish already queued wakes the session at once, so "ready" settles first.
setup
run "$(prompt_json d14 a)"
SETTLE_SECONDS=2 run "$(work_json d14 a '[]')"
check "ready waits for the session to settle" 0
run "$(wake_json d14 b)"
sleep 3
check "an immediate wake cancels ready" 0
run "$(work_json d14 b '[]')"
check "the real finish then alerts" 1
teardown

setup
run "$(prompt_json d15 a)"
SETTLE_SECONDS=1 run "$(work_json d15 a '[]')"
sleep 3
check "a settled finish is delivered after the hook returns" 1
teardown

setup
run "$(prompt_json d16 a)"
run "$(work_json d16 a "$(task shell 'curl -H secret-marker example.invalid')")"
if grep -q secret-marker "$SANDBOX/.claude/hooks/turn-notify.log"; then
  FAIL=$((FAIL + 1)); printf '  FAIL the log leaked a command\n'
else
  PASS=$((PASS + 1)); printf '  ok   the log never records commands\n'
fi
teardown

# --- Messages from other sessions -------------------------------------------

for text in '<cross-session-message from="uds:/tmp/x"> checked, no change' \
  '<agent-message from="reviewer"> finished' \
  'Another Claude session sent a message: <cross-session-message from="uds:/tmp/x"> hi' \
  'A peer session sent a message while you were working: <agent-message from="x"> hi'; do
  setup
  run "$(prompt_json d17 a)"
  run "$(work_json d17 a '[]')"
  : >"$SANDBOX/calls"
  run "$(prompt_json d17 b "$text")"
  run "$(work_json d17 b '[]')"
  check "another session's message is not the captain's prompt: ${text:0:28}" 0
  teardown
done

setup
run "$(prompt_json d18 a)"
run "$(work_json d18 a '[]')"
: >"$SANDBOX/calls"
run "$(prompt_json d18 b 'Another Claude session sent a message to me earlier, what was it?')"
run "$(work_json d18 b '[]')"
check "a human asking about such a message still alerts" 1
teardown

# --- Failures inside an agent ---------------------------------------------
#
# Claude fires StopFailure for these too, with the agent's id and the MAIN
# turn's prompt id (captured live, 2026-11-22).

agent_failure() {
  printf '{"hook_event_name":"StopFailure","session_id":"%s","prompt_id":"%s","agent_id":"a1facf","agent_type":"general-purpose","cwd":"/tmp/p","error":"invalid_request"}' "$1" "$2"
}

setup
run "$(agent_failure a1 a)"
check "an agent's failure is not the session's failure" 0
teardown

setup
run "$(prompt_json a2 a)"
run "$(agent_failure a2 a)"
: >"$SANDBOX/calls"
run "$(work_json a2 a '[]')"
check "an agent's failure cannot mute the session's finish" 1
teardown

setup
run "$(agent_failure a3 a)"
: >"$SANDBOX/calls"
run '{"hook_event_name":"StopFailure","session_id":"a3","prompt_id":"a","cwd":"/tmp/p","error":"overloaded"}'
check "an agent's failure cannot use up the real failure's cooldown" 1
teardown

setup
run "$(prompt_json a4 a)"
SETTLE_SECONDS=2 run "$(work_json a4 a '[]')"
run "$(agent_failure a4 a)"
: >"$SANDBOX/calls"
sleep 3
check "an agent's failure cannot withdraw a settling ready" 1
teardown

setup
run '{"hook_event_name":"Notification","session_id":"a5","agent_id":"a1facf","notification_type":"permission_prompt","message":"needs approval"}'
check "an agent that needs approval still alerts" 1
teardown

# --- Is it still waiting? ---------------------------------------------------
#
# Claude can open a permission check that clears by itself seconds after the
# notification (seen twice on 2026-11-22, each about 12 seconds in all). Its
# session record says whether it is still waiting.

record() {
  mkdir -p "$SANDBOX/.claude/sessions"
  printf '{"sessionId":"%s","status":"%s"}' "$1" "$2" >"$SANDBOX/.claude/sessions/100.json"
}
permission() {
  printf '{"hook_event_name":"Notification","session_id":"%s","notification_type":"permission_prompt","message":"needs approval"}' "$1"
}

setup
record w1 busy
run "$(permission w1)"
check "a permission check that already cleared stays silent" 0
teardown

setup
record w2 waiting
run "$(permission w2)"
check "a session still waiting alerts" 1
teardown

setup
record w3 waiting
CONFIRM_SECONDS=2 run "$(permission w3)"
check "a permission alert is confirmed before it is sent" 0
record w3 busy
sleep 3
check "a check that clears during confirmation stays silent" 0
teardown

setup
record w4 waiting
CONFIRM_SECONDS=1 run "$(permission w4)"
sleep 3
check "a confirmed wait is delivered after the hook returns" 1
teardown

setup
record someone-else busy
run "$(permission w5)"
check "an unreadable waiting state fails open" 1
teardown

setup
record w6 busy
run '{"hook_event_name":"Notification","session_id":"w6","notification_type":"push_notification","message":"Decision needed"}'
check "a pushed message needs no confirmation" 1
teardown

# --- Wording: title "Firstmate: <tab name>", message opens with the state.

note_json() {
  printf '{"hook_event_name":"Notification","session_id":"%s","cwd":"/tmp/project","notification_type":"%s","message":"Decision needed"}' "$1" "$2"
}

setup
printf 'Long internal topic nobody sees' >"$SANDBOX/pane-title"
printf 'web-O' >"$SANDBOX/tab-name"
run_plain "$(note_json t1 push_notification)"
check_contains "a pushed note names the tab and says it is a message" "--title Firstmate: web-O --body Message: Decision needed"
check_lacks "a pushed note does not claim Claude is blocked" "Needs you"
check_lacks "a named tab is not renamed to Claude's topic" "Long internal topic"
teardown

setup
printf 'web-O' >"$SANDBOX/tab-name"
run_plain "$(note_json t2 permission_prompt)"
check_contains "a blocked session names the tab" "--title Firstmate: web-O --body Needs you: "
teardown

setup
printf 'web-O' >"$SANDBOX/tab-name"
run_plain "$(work_json t3 a '[]')"
check_contains "a finish names the tab" "--title Firstmate: web-O --body Ready: "
teardown

setup
printf 'web-O' >"$SANDBOX/tab-name"
run_plain '{"hook_event_name":"StopFailure","session_id":"t4","cwd":"/tmp/project","error":"overloaded"}'
check_contains "a failure names the tab" "--title Firstmate: web-O --body Error: "
teardown

setup
printf '* Fix the weekly report' >"$SANDBOX/pane-title"
run_plain "$(note_json t5 permission_prompt)"
check_contains "an unnamed tab is named by its topic" "--title Firstmate: Fix the weekly report --body Needs you: Decision needed"
teardown

setup
printf '/dev/ttys902' >"$SANDBOX/pane-tty"
printf 'notes' >"$SANDBOX/tab-name"
run "$(note_json t6 permission_prompt)"
check_contains "a tmux session names the tab showing it" "--title Firstmate: notes --body Needs you: "
check_contains "and its click still goes by session" "claudejump://testsession"
teardown

setup
run "$(note_json t7 permission_prompt)"
check_contains "a detached tmux session is named by the session" "--title Firstmate: testsession --body Needs you: "
teardown

setup
printf 'a very long tab name that would push the state out of sight' >"$SANDBOX/tab-name"
run_plain "$(note_json t8 permission_prompt)"
check_contains "a long tab name cannot hide the state" "--title Firstmate: a very long tab name t... --body Needs you: "
teardown

setup
run_plain "$(note_json t9 permission_prompt)"
check_contains "a tab with neither name nor topic is named by its folder" "--title Firstmate: project --body Needs you: "
teardown

setup
printf '/dev/ttys903' >"$SANDBOX/pane-tty"
run "$(note_json t10 permission_prompt)"
check_contains "an unnamed tab showing tmux is named by the session" "--title Firstmate: testsession --body Needs you: "
teardown

# --- Clicking ----------------------------------------------------------------

jump() { env HOME="$SANDBOX" JUMP_PATH="$SANDBOX/bin" bash "$JUMP" "$1" >/dev/null 2>&1; }

setup
printf '/dev/ttys900' >"$SANDBOX/pane-tty"
jump 'claudejump://wezterm/7/ttys900'
if grep -q -- '--pane-id 7' "$SANDBOX/activated" 2>/dev/null; then
  PASS=$((PASS + 1)); printf '  ok   a click activates the plain pane\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL a click did not activate the plain pane\n'
fi
teardown

setup
printf '/dev/ttys901' >"$SANDBOX/pane-tty"
jump 'claudejump://wezterm/7/ttys900'
if [ -e "$SANDBOX/activated" ]; then
  FAIL=$((FAIL + 1)); printf '  FAIL a stale click opened another tab\n'
else
  PASS=$((PASS + 1)); printf '  ok   a stale click cannot open another tab\n'
fi
teardown

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
