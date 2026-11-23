#!/bin/bash
# Desktop notification when an interactive Claude Code session needs the captain,
# in a plain terminal tab or inside tmux.
#
# Wired to global hook events in ~/.claude/settings.json, so every session of
# this account is covered. No discovery, no polling.
#
#   Stop          the captain's work is finished                  -> attention
#   StopFailure   the turn died and needs restarting              -> urgent
#   Notification  blocked mid-turn, waiting on the captain        -> attention
#
# Never send the routine level from here. macOS delivers it muted, and when
# FirstMate uses the Persistent style a muted alert that starts the app's stack
# hides every later alert in it, finished turns and errors included, until the
# stack is cleared (measured 2026-11-22 on macOS 27.2.1). The wording, not the
# level, is what distinguishes a blocked session from a finished one: the title
# is "Firstmate: <tab name>" and the message opens with the state. The name is
# capped, because macOS cuts long titles at the end.
#
# Safety: this runs inside turn teardown and notification dispatch. Every path
# exits 0 so a problem here can never block or fail a turn.
#
#
# WHAT "DONE" MEANS
#
# One "ready" for each prompt the captain submits, sent at the first turn end
# where no work that will wake the session is left. Three facts decide it:
#
#   1. WHO fired the hook. Claude labels scripted runs in
#      CLAUDE_CODE_ENTRYPOINT. In tmux the interactive session is the process
#      directly in the pane; elsewhere it has a terminal and no Claude process
#      above it. Everything a pipeline or another session spawns is excluded.
#   2. WHAT is still running. The Stop payload lists it in background_tasks and
#      session_crons. Agents, workflows, monitors, jobs and one-time wake-ups
#      hold "ready". Servers, repeating schedules and housekeeping do not: they
#      never finish, so they would hold it forever.
#   3. WHETHER an alert is owed. A prompt from the captain creates the debt, a
#      turn that ends with work running keeps it, and the alert consumes it.
#      Machine wakes cannot create one once the session's history is known.
#
# Each of these alone has failed before. "Silent while anything runs" lost seven
# of eight alerts on 2026-08-15 (no exception for work that never ends, and no
# alert at the eventual finish). "Any prompt event is human" caused the flood of
# 2026-09-01 (background wakes and `claude -p` fire that event too). "Only the
# turn a human started" then announced hand-offs and stayed silent at the real
# finish. Change one only with the other two in view.
#
# Every check fails OPEN. An unresolved origin, a missing work report or unknown
# history alerts. Silence is indistinguishable from "still working", and that is
# how this went dead for sixteen days in August.

set -u

HOOK_DIR="$HOME/.claude/hooks"
LOG="$HOOK_DIR/turn-notify.log"
IGNORE="$HOOK_DIR/turn-notify-ignore"
STATE_DIR="$HOOK_DIR/.turn-notify-state"

# Global off switch. Create this file to silence every alert without touching
# settings.json, so re-enabling is `rm` and no config drifts while it is off.
#
# It EXPIRES. On 2026-08-16 this file was created - most likely to stop banners
# during a test run - and never removed, leaving the captain with no alerts for
# sixteen days. Nothing surfaced the outage because a silenced notifier and a
# quiet fleet look identical. A temporary silence must not be able to become a
# permanent one by accident, so the flag lapses after a day unless it explicitly
# says otherwise (write the word "permanent" into it to keep it indefinitely).
DISABLED="$HOOK_DIR/turn-notify-disabled"
DISABLE_MAX_AGE_SECONDS="${DISABLE_MAX_AGE_SECONDS:-86400}"

NOTIFY="$HOME/.local/bin/firstmate-notify"
if [ ! -x "$NOTIFY" ]; then
  NOTIFY="$(command -v firstmate-notify 2>/dev/null || true)"
fi

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true
}

# Keep the log bounded; it is a debugging aid, not a record of value.
if [ -f "$LOG" ] && [ "$(wc -c <"$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
  tail -n 500 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null || true
fi

input="$(cat 2>/dev/null || true)"

jqf() {
  printf '%s' "$input" | jq -r "$1" 2>/dev/null || true
}

event="$(jqf '.hook_event_name // "Stop"')"
cwd="$(jqf '.cwd // ""')"
reason="$(jqf '.error // ""')"
ntype="$(jqf '.notification_type // ""')"
sid="$(jqf '.session_id // ""')"
pid_key="$(jqf '.prompt_id // ""')"
agent="$(jqf '.agent_id // ""')"

# Collapse text to one safe, bounded line. iconv drops any partial multibyte
# character left behind by a byte-wise truncation.
one_line() {
  printf '%s' "$1" \
    | tr '\n\r\t' '   ' \
    | tr -d '\000-\037' \
    | sed 's/  */ /g; s/^ //; s/ $//' \
    | cut -c1-180 \
    | iconv -c -f UTF-8 -t UTF-8 2>/dev/null || true
}

state_file() {
  # state_file <kind> <key>
  local kind="$1" raw="$2" key
  [ -n "$raw" ] || return 1
  key="$(printf '%s' "$raw" | sed 's/[^A-Za-z0-9._-]/_/g' 2>/dev/null)"
  [ -n "$key" ] || return 1
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  printf '%s/%s-%s' "$STATE_DIR" "$kind" "$key"
}

# Which claude process fired this hook, and is the captain looking at it?
#
#   interactive   a session of the captain's
#   programmatic  started by a script, a tool or another session
#   unknown       could not be resolved; the caller must fail open
#
# Prints the verdict and the session's tty. One `ps` snapshot and one `awk`
# pass, because this runs on every hook event.
session_origin() {
  local pane_pid="" snapshot

  case "${CLAUDE_CODE_ENTRYPOINT:-}" in
    sdk-* | mcp | claude-code-github-action) printf 'programmatic -'; return 0 ;;
  esac

  if [ "$in_tmux" -eq 1 ]; then
    pane_pid="$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null || true)"
    case "$pane_pid" in
      '' | *[!0-9]*) printf 'unknown -'; return 0 ;;
    esac
  fi

  snapshot="$(ps -axo pid=,ppid=,tty=,command= 2>/dev/null)" || { printf 'unknown -'; return 0; }
  [ -n "$snapshot" ] || { printf 'unknown -'; return 0; }

  printf '%s' "$snapshot" | awk -v start="$$" -v pane="$pane_pid" '
    # A claude session: the launcher on PATH, or a version-pinned binary under
    # .../claude/versions/<v>. Matched on argv[0] only, so a shell command that
    # merely mentions ~/.claude cannot be mistaken for one.
    function is_session(a,   base) {
      base = a
      sub(/^.*\//, "", base)
      return base == "claude" || a ~ /\/claude\/versions\//
    }
    { P[$1] = $2; T[$1] = $3; A[$1] = $4 }
    END {
      p = start
      for (n = 0; n < 25; n++) {
        if (!(p in P)) break
        if (is_session(A[p])) {
          if (pane != "") {
            print ((p == pane || P[p] == pane) ? "interactive" : "programmatic"), T[p]
            exit
          }
          if (T[p] !~ /^tty/) { print "programmatic -"; exit }
          q = P[p]
          for (m = 0; m < 25 && (q in P); m++) {
            if (is_session(A[q])) { print "programmatic -"; exit }
            q = P[q]
          }
          print "interactive", T[p]
          exit
        }
        if (pane != "" && p == pane) break
        p = P[p]
      }
      print "unknown -"
    }
  ' 2>/dev/null || printf 'unknown -'
}

# Did a human type this, or did the machine generate it?
#
# A background job finishing, or another Claude session sending a message,
# wakes a session by submitting a prompt, and that prompt is machine-authored
# with a marker at the very front. Matching only on a
# leading marker keeps this conservative: anything unrecognised counts as human,
# so a new marker shape costs an extra alert rather than silence.
is_machine_prompt() {
  local p
  p="$(printf '%s' "$1" | sed 's/^[[:space:]]*//' 2>/dev/null)"
  case "$p" in
    '<task-notification>'*) return 0 ;;
    '[SYSTEM NOTIFICATION'*) return 0 ;;
    '<system-reminder>'*) return 0 ;;
    '<cross-session-message'* | '<agent-message'*) return 0 ;;
    'Another Claude session sent a message'* | 'A peer session sent a message'*)
      # The wrapper alone could be typed; with the tag it cannot be.
      case "${p:0:400}" in
        *'<cross-session-message'* | *'<agent-message'*) return 0 ;;
      esac
      return 1
      ;;
    *) return 1 ;;
  esac
}

# Per-session cooldown for repeated failure alerts.
#
# A session failing in a loop used to alert on every attempt: four urgent
# banners from one session inside 64 seconds was measured on 2026-08-14. The
# captain needs to learn that a session broke, not to be told again each time it
# retries. The window is keyed by session, so a second session failing still
# alerts immediately rather than being hidden behind the first one's cooldown.
FAILURE_COOLDOWN_SECONDS="${FAILURE_COOLDOWN_SECONDS:-300}"

failure_alert_allowed() {
  local stamp last now
  stamp="$(state_file fail "${sid:-$sess}")" || return 0
  now="$(date +%s 2>/dev/null)" || return 0
  [ -n "$now" ] || return 0
  if [ -f "$stamp" ]; then
    last="$(cat "$stamp" 2>/dev/null)"
    case "$last" in
      '' | *[!0-9]*) last="" ;;
    esac
    if [ -n "$last" ] && [ "$(( now - last ))" -lt "$FAILURE_COOLDOWN_SECONDS" ]; then
      return 1
    fi
  fi
  printf '%s' "$now" >"$stamp" 2>/dev/null || true
  return 0
}

# Is work left that will wake this session by itself? Prints three fields:
# hold|clear|unknown, what was counted, and what was deliberately not counted.
# Types are logged; commands and prompts never are.
#
# A server is recognised only as the final, foreground command of a background
# shell. Anything unrecognised is a job and holds: of 570 background shells
# measured over a week, 528 finished by themselves and four were servers.
work_report() {
  local report
  report="$(printf '%s' "$input" | jq -r '
    def server:
      (. // "")
      | gsub("[0-9]?>&[0-9]|&>"; ">")
      | [splits("&&|\\|\\||;|\n") | gsub("^\\s+|\\s+$"; "") | select(length > 0 and (startswith("#") | not))]
      | (last // "")
      | (contains("|") | not) and (endswith("&") | not) and test(
          "^([A-Za-z_][A-Za-z0-9_]*=\\S+\\s+)*(exec\\s+)?(npx\\s+|bunx\\s+|uv\\s+run\\s+|poetry\\s+run\\s+)?(" +
          "(npm|pnpm|yarn|bun)(\\s+-\\S+(\\s+[^-\\s]\\S*)?)*\\s+(run\\s+)?(dev(:\\S+)?|start|serve|preview)(\\s|$)" +
          "|next\\s+(dev|start)(\\s|$)" +
          "|vite(\\s+(dev|serve|preview)(\\s|$)|\\s+-|\\s*$)" +
          "|astro\\s+(dev|preview)(\\s|$)" +
          "|(\\S*/)?python[0-9.]*\\s+(-[A-Za-z]+\\s+)*-m\\s+http\\.server(\\s|$)" +
          "|(\\S*/)?python[0-9.]*\\s+(\\S*/)?manage\\.py\\s+runserver(\\s|$)" +
          "|uvicorn\\s|http-server(\\s|$)|ngrok\\s+http\\s|cloudflared\\s+tunnel\\s" +
          "|tail\\s+-[A-Za-z0-9]*[fF](\\s|$))");
    if (.background_tasks | type) != "array" or (.session_crons | type) != "array" then
      "unknown\tnone\tno-work-report"
    else
      ([.background_tasks[]
        | if .type == "shell" then
            (if (.command | server) then {k: "server"} else {k: "shell", hold: true} end)
          elif (.type | IN("subagent", "monitor", "workflow", "teammate", "MCP task", "cloud session")) then
            {k: .type, hold: true}
          else {k: .type} end]
       + [.session_crons[]
          | if .recurring then {k: "repeating"} else {k: "wake-up", hold: true} end]) as $w
      | [$w[] | select(.hold) | .k] as $held
      | [$w[] | select(.hold | not) | .k] as $free
      | [(if ($held | length) > 0 then "hold" else "clear" end),
         (if ($held | length) > 0 then ($held | join(",")) else "none" end),
         (if ($free | length) > 0 then ($free | join(",")) else "none" end)] | @tsv
    end' 2>/dev/null)" || report=""
  if [ -n "$report" ]; then printf '%s' "$report"; else printf 'unknown\tnone\tunreadable'; fi
}

# A repeating schedule submits its prompt exactly as if it had been typed, so
# its fingerprints are kept to recognise those turns. No prompt text is stored.
fingerprints() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s' "$line" | shasum | cut -d' ' -f1
  done
}

remember_loops() {
  local file
  file="$(state_file loops "$sid")" || return 0
  jqf '.session_crons | arrays | .[] | select(.recurring) | .prompt[0:900] | @base64' \
    | fingerprints >"$file" 2>/dev/null || true
}

is_loop_prompt() {
  local file print
  file="$(state_file loops "$sid")" || return 1
  [ -s "$file" ] || return 1
  print="$(jqf '(.prompt // "")[0:900] | @base64' | fingerprints)"
  [ -n "$print" ] && grep -qxF "$print" "$file" 2>/dev/null
}

# Where a click should land, and what to call the session.
#
# The label is the name the captain gave the tab, because that is what they
# look for in the tab bar. A tab left unnamed shows only "claude" there, so it
# is labelled by Claude's topic instead, then by folder. An unnamed tab showing
# tmux is labelled by the session.
# The pane is found by tty, never WEZTERM_PANE, which is inherited and can be
# stale; for tmux that is the tty of the client showing the session.
resolve_place() {
  target=""
  label="$sess"
  local at="" found pane name title
  if [ "$in_tmux" -eq 1 ]; then
    # Percent-encoded so names with spaces or punctuation survive the round trip.
    target="$(printf '%s' "$sess" | jq -sRr @uri 2>/dev/null || true)"
    [ -n "$target" ] || target="$sess"
    at="$(tmux list-clients -F '#{client_tty} #{client_session}' 2>/dev/null \
      | awk -v s="$sess" '{ t = $1; sub(/^[^ ]+ /, ""); if ($0 == s) { print t; exit } }')"
  else
    case "$tty" in tty*) at="/dev/$tty" ;; esac
  fi
  case "$at" in /dev/*) ;; *) return 0 ;; esac
  command -v wezterm >/dev/null 2>&1 || return 0

  # Bounded: a wedged terminal must cost the tab name, never the alert.
  found="$(perl -e 'alarm 3; exec @ARGV' wezterm cli --no-auto-start list --format json </dev/null 2>/dev/null \
    | jq -r --arg t "$at" '
        map(select(.tty_name == $t)) | .[0] // empty
        | [(.pane_id | tostring), (.tab_title // ""), (.title // "")]
        | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")' 2>/dev/null)"
  IFS="$(printf '\037')" read -r pane name title <<EOT
$found
EOT
  case "$pane" in '' | *[!0-9]*) return 0 ;; esac
  [ "$in_tmux" -eq 1 ] || target="wezterm/$pane/${at#/dev/}"

  name="$(one_line "$name")"
  if [ -z "$name" ] && [ "$in_tmux" -eq 0 ]; then
    # Claude's title opens with a status glyph; drop it.
    name="$(one_line "$title" | LC_ALL=C sed -E 's/^[^[:alnum:] ]+ +//')"
    case "$name" in "Claude Code" | claude | zsh | bash) name="" ;; esac
  fi
  [ -n "$name" ] || return 0
  if [ "${#name}" -gt 25 ]; then
    name="$(printf '%s' "${name:0:22}" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null)..."
  fi
  label="$name"
}

# Is Claude still waiting on the captain? Its own session record says so. That
# file is not a documented interface, so only a readable "not waiting" counts
# as no. Anything else fails open.
still_waiting() {
  local file status
  [ -n "$sid" ] || return 0
  for file in "$HOME"/.claude/sessions/*.json; do
    [ -f "$file" ] || continue
    status="$(jq -r --arg s "$sid" 'select(.sessionId == $s) | .status // empty' "$file" 2>/dev/null)"
    case "$status" in
      busy | idle) return 1 ;;
      ?*) return 0 ;;
    esac
  done
  return 0
}

# deliver <level> <state> <body>
deliver() {
  local level="$1" state="$2" body="$3" rc=1
  if [ -z "$NOTIFY" ]; then
    log "FAILED no firstmate-notify on PATH session=$sess event=$event"
    return 1
  fi
  resolve_place
  body="$state: $body"

  if [ -n "$target" ]; then
    "$NOTIFY" notify \
      --source claude-turn \
      --level "$level" \
      --title "Firstmate: $label" \
      --body "$body" \
      --action-type url \
      --action-value "claudejump://$target" >/dev/null 2>&1
    rc=$?
  fi

  # A missing or refused click action must never cost the captain the
  # notification itself, which is the whole point of this hook.
  if [ "$rc" -ne 0 ]; then
    "$NOTIFY" notify \
      --source claude-turn \
      --level "$level" \
      --title "Firstmate: $label" \
      --body "$body" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && [ -n "$target" ] && log "jump action refused by notifier; sent plain notification"
  fi

  if [ "$rc" -eq 0 ]; then
    log "notified tab=\"$label\" state=\"$state\" session=$sess event=$event${ntype:+ type=$ntype} origin=$origin sid=$sid reason=${reason:-none} target=${target:-none} cwd=$cwd"
  else
    log "FAILED notify rc=$rc session=$sess event=$event${ntype:+ type=$ntype}"
  fi
  return "$rc"
}

# Checked after stdin is consumed, so disabling never leaves the caller writing
# into a closed pipe.
if [ -f "$DISABLED" ]; then
  disabled_now="$(date +%s 2>/dev/null || echo 0)"
  disabled_at="$(stat -L -f %m "$DISABLED" 2>/dev/null || echo 0)"
  if grep -qi 'permanent' "$DISABLED" 2>/dev/null; then
    log "skip disabled event=$event (marked permanent; rm $DISABLED to re-enable)"
    exit 0
  elif [ "$disabled_now" -gt 0 ] && [ "$disabled_at" -gt 0 ] \
    && [ "$(( disabled_now - disabled_at ))" -ge "$DISABLE_MAX_AGE_SECONDS" ]; then
    rm -f "$DISABLED" 2>/dev/null || true
    log "off switch expired after ${DISABLE_MAX_AGE_SECONDS}s and was cleared; alerting resumes"
  else
    log "skip disabled event=$event (rm $DISABLED to re-enable)"
    exit 0
  fi
fi

in_tmux=0
if [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  in_tmux=1
  # Resolve live rather than caching, so renamed or moved panes stay correct.
  sess="$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null || true)"
  [ -n "$sess" ] || sess="tmux"

  # The list names tmux sessions. Outside tmux the fallback name is only a
  # folder, which must not be muted for sharing a name with one.
  if [ -f "$IGNORE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      line="$(printf '%s' "$line" | tr -d '[:space:]')"
      [ -n "$line" ] || continue
      if [ "$line" = "$sess" ]; then
        log "skip ignored session=$sess event=$event"
        exit 0
      fi
    done <"$IGNORE"
  fi
else
  sess="$(one_line "${cwd##*/}")"
  [ -n "$sess" ] || sess="Claude"
fi

# Gate every event, not just Stop. A sub-session's prompt events must not reach
# the state directory either, or they would leave markers the captain's real
# session is later judged against.
read -r origin tty <<EOT
$(session_origin)
EOT
if [ "$origin" = "programmatic" ]; then
  log "skip programmatic-session session=$sess event=$event sid=$sid entry=${CLAUDE_CODE_ENTRYPOINT:-none} cwd=$cwd"
  exit 0
fi

# An event from inside a subagent (agent_id is set only there) says nothing
# about the session's own turn. An agent's failure arrives as StopFailure with
# the MAIN turn's prompt id, so it must not alert, start the cooldown or touch
# any state. The main thread hears of it and reports. An agent asking for
# approval is different: that needs the captain, so Notification passes.
if [ -n "$agent" ] && [ "$event" != "Notification" ]; then
  log "skip subagent-event session=$sess event=$event sid=$sid agent=$agent reason=${reason:-none}"
  exit 0
fi

# Per-session state:
#   tracked   prompt events arrive, so the absence of a debt is real evidence
#   owed      an alert is owed
#   pending   the "ready" now settling; any newer turn event replaces it
#   failed    the prompt id of the turn that died
#   loops     fingerprints of repeating prompts
tracked="$(state_file tracked "$sid")" || tracked=""
owed="$(state_file owed "$sid")" || owed=""
pending="$(state_file pending "$sid")" || pending=""
failed="$(state_file failed "$sid")" || failed=""
token="$$.$RANDOM"
case "$event" in
  UserPromptSubmit | Stop | StopFailure)
    [ -n "$pending" ] && printf '%s' "$token" >"$pending" 2>/dev/null
    ;;
esac

case "$event" in
  UserPromptSubmit)
    # Records whether an alert is now owed; never notifies anything itself.
    if is_machine_prompt "$(jqf '.prompt // ""')" || is_loop_prompt; then
      if [ -n "$tracked" ] && [ ! -f "$tracked" ]; then
        # History unknown (work handed off before tracking began): fail open once.
        [ -n "$owed" ] && : >"$owed" 2>/dev/null
        log "machine wake, history unknown session=$sess sid=$sid prompt=$pid_key (alert owed)"
      else
        log "machine wake session=$sess sid=$sid prompt=$pid_key"
      fi
    else
      [ -n "$owed" ] && : >"$owed" 2>/dev/null
      log "captain prompt session=$sess sid=$sid prompt=$pid_key"
    fi
    [ -n "$tracked" ] && : >"$tracked" 2>/dev/null

    # Bound growth: markers older than a week cannot belong to a live session.
    find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null || true
    exit 0
    ;;

  Notification)
    # Filter by exclusion, not by an allowlist: a notification type nobody
    # anticipated is far more likely to mean "the captain is needed" than not,
    # and a missed alert leaves a session stalled indefinitely. Only types known
    # to be redundant or uninteresting are dropped here.
    #
    #   agent_completed        already covered by the Stop event
    #   idle_prompt            fires when the input box sits untouched, which
    #                          would nag a second time about a finished turn
    #   auth_success           informational, needs nothing
    #   elicitation_complete   the dialog is already answered
    #   elicitation_response   the dialog is already answered
    #   computer_use_*         a status change, needs nothing
    #   quota_auto_resume_fired  the session resumed by itself
    case "$ntype" in
      agent_completed|idle_prompt|auth_success|elicitation_complete|elicitation_response|computer_use_enter|computer_use_exit|quota_auto_resume_fired)
        log "skip notification session=$sess type=$ntype"
        exit 0
        ;;
    esac
    state="Needs you"
    # Claude chose to send this one (PushNotification). It can carry a decision,
    # so it alerts, but it does not mean the session is blocked.
    [ "$ntype" = "push_notification" ] && state="Message"
    level="attention"
    body="$(one_line "$(jqf '.message // ""')")"
    [ -n "$body" ] || body="Claude is waiting on you before it can continue."

    # Claude can open a permission check that clears by itself seconds after
    # notifying, which left alerts with nothing to answer. So this one type is
    # sent only if it is still waiting a moment later. Questions and real
    # approvals stay "waiting" until answered (measured 2026-11-22).
    if [ "$ntype" = "permission_prompt" ]; then
      confirm() {
        [ "$CONFIRM_SECONDS" = 0 ] || sleep "$CONFIRM_SECONDS"
        if still_waiting; then
          deliver "$level" "$state" "$body"
        else
          log "withdrawn, no longer waiting session=$sess sid=$sid type=$ntype"
        fi
      }
      CONFIRM_SECONDS="${CONFIRM_SECONDS:-8}"
      if [ "$CONFIRM_SECONDS" = 0 ]; then
        confirm
      else
        ( trap '' HUP; confirm ) </dev/null >/dev/null 2>&1 &
      fi
      exit 0
    fi
    ;;

  StopFailure)
    # A broken session needs restarting whoever started the turn, so only the
    # cooldown applies. The debt survives: background work can outlive the dead
    # turn, and its finish must still be announced.
    [ -n "$failed" ] && printf '%s' "$pid_key" >"$failed" 2>/dev/null
    if ! failure_alert_allowed; then
      log "skip failure-cooldown session=$sess sid=$sid window=${FAILURE_COOLDOWN_SECONDS}s"
      exit 0
    fi
    state="Error"
    level="urgent"
    body="The turn ended early${reason:+ ($reason)} and needs restarting."
    snippet="$(one_line "$(jqf '.last_assistant_message // ""')")"
    [ -n "$snippet" ] && body="$body $snippet"
    ;;

  *)
    IFS="$(printf '\t')" read -r work held free <<EOT
$(work_report)
EOT
    remember_loops
    is_owed=no; [ -n "$owed" ] && [ -f "$owed" ] && is_owed=yes
    is_tracked=no; [ -n "$tracked" ] && [ -f "$tracked" ] && [ -n "$pid_key" ] && is_tracked=yes
    facts="session=$sess sid=$sid prompt=${pid_key:-none} owed=$is_owed tracked=$is_tracked work=$work held=$held not-held=$free"

    if [ -n "$pid_key" ] && [ -n "$failed" ] && [ "$(cat "$failed" 2>/dev/null)" = "$pid_key" ]; then
      log "skip failed-turn $facts"
      exit 0
    fi
    if [ "$work" = "hold" ]; then
      # With no history, take on the debt so the eventual finish still alerts.
      [ "$is_tracked" = no ] && [ -n "$owed" ] && : >"$owed" 2>/dev/null
      log "waiting $facts"
      exit 0
    fi
    if [ "$is_owed" = no ] && [ "$is_tracked" = yes ]; then
      log "skip nothing-owed $facts"
      exit 0
    fi
    log "ready $facts"

    level="attention"
    state="Ready"
    body="$(one_line "$(jqf '.last_assistant_message // ""')")"
    [ -n "$body" ] || body="Claude finished and is waiting for your next prompt."

    # A finish that is already queued wakes the session at once (about one wake
    # in sixteen arrived within three seconds), so let the session settle and
    # withdraw if it did. Detached, so the turn is never held up.
    announce() {
      if [ "$SETTLE_SECONDS" != 0 ] && [ -n "$pending" ]; then
        sleep "$SETTLE_SECONDS"
        if [ "$(cat "$pending" 2>/dev/null)" != "$token" ]; then
          log "ready withdrawn, session resumed sid=$sid"
          return 0
        fi
      fi
      [ -n "$owed" ] && rm -f "$owed" 2>/dev/null
      if ! deliver "$level" "$state" "$body"; then
        [ -n "$owed" ] && : >"$owed" 2>/dev/null
      fi
    }

    SETTLE_SECONDS="${SETTLE_SECONDS:-3}"
    if [ "$SETTLE_SECONDS" = 0 ]; then
      announce
    else
      ( trap '' HUP; announce ) </dev/null >/dev/null 2>&1 &
    fi
    exit 0
    ;;
esac

deliver "$level" "$state" "$body"
exit 0
