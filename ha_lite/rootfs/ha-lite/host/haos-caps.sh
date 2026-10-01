#!/bin/sh
# haos-caps.sh -- runs on the Home Assistant OS HOST (installed by the HA Lite add-on). POSIX sh.
# Keeps soft memory caps (memory.high, never memory.max) on chosen containers. A cap lives on the container's
# cgroup and every container (re)start creates a new cgroup, so this runs as a small daemon.
#  - grace: a cap is applied GRACE seconds after a container starts (startup peaks are above the steady state).
#  - safety valve: every CHECK seconds, if a capped container's PSI "some" avg60 > PSI_LIFT %, its cap is lifted
#    (memory.high=max) for BACKOFF seconds, then re-applied. Logged.
#  - healer: for each app slug in haos-heal.conf, if its container is not running AND the Supervisor logged a
#    watchdog failure or a missing-device error for it since it was last seen running, start it through the
#    Supervisor every HEAL_EVERY seconds until it runs. (The Supervisor watchdog retries once; a USB stick that
#    comes back a few seconds later leaves the app down.) A manual stop logs neither, so it is left alone.
#    Pause one app: touch $RUN/heal.pause.<slug>; all: touch $DIR/heal.off.
# Subcommands: run (daemon) | apply-now | status | undo (stop daemon, all caps -> max).
# Config: $DIR/haos-caps.conf, lines "<container> <MB>" (# comments). Log: $DIR/caps.log.
set -u
DIR=/mnt/data/haos-caps; CONF=$DIR/haos-caps.conf; LOG=$DIR/caps.log; RUN=/run/haos-caps
GRACE=${GRACE:-600}; CHECK=${CHECK:-60}; PSI_LIFT=${PSI_LIFT:-10}; BACKOFF=${BACKOFF:-3600}
HCONF=$DIR/haos-heal.conf; HEAL_EVERY=${HEAL_EVERY:-120}
mkdir -p "$RUN"
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; [ "$(wc -c < "$LOG")" -gt 262144 ] && tail -500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
cg(){ id=$(docker inspect -f '{{.Id}}' "$1" 2>/dev/null) || return 1; echo "/sys/fs/cgroup/system.slice/docker-$id.scope"; }
mb_for(){ awk -v c="$1" '$1==c{print $2}' "$CONF"; }
started_s(){ t=$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null) || return 1; date -u -d "$(echo "$t" | cut -c1-19 | tr T ' ')" +%s; }

apply(){ # $1 container; honours grace and backoff
  c=$1; mb=$(mb_for "$c"); [ -n "$mb" ] || return 0
  d=$(cg "$c") || return 0; [ -f "$d/memory.high" ] || return 0
  now=$(date +%s); st=$(started_s "$c") || return 0
  [ $((now - st)) -lt "$GRACE" ] && return 0
  if [ -f "$RUN/backoff.$c" ] && [ "$now" -lt "$(cat "$RUN/backoff.$c")" ]; then return 0; fi
  want=$((mb * 1048576)); cur=$(cat "$d/memory.high")
  [ "$cur" = "$want" ] && return 0
  echo "${mb}M" > "$d/memory.high" && log "cap $c = ${mb}M (was $cur; current=$(( $(cat "$d/memory.current") / 1048576 ))M)"
}

valve(){ # lift a cap whose container is under sustained pressure
  c=$1; mb=$(mb_for "$c"); [ -n "$mb" ] || return 0
  d=$(cg "$c") || return 0; [ "$(cat "$d/memory.high" 2>/dev/null)" = "max" ] && return 0
  p=$(awk '/^some/{split($3,a,"=");print a[2]}' "$d/memory.pressure")
  if awk "BEGIN{exit !($p > $PSI_LIFT)}"; then
    echo max > "$d/memory.high"; echo $(( $(date +%s) + BACKOFF )) > "$RUN/backoff.$c"
    log "VALVE: $c PSI some avg60=$p% > $PSI_LIFT% -> cap lifted for ${BACKOFF}s"
  fi
}

heal(){ # $1 app slug (container app_<slug>)
  a=$1; c=app_$a; now=$(date +%s)
  if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ]; then echo "$now" > "$RUN/seen.$a"; rm -f "$RUN/tried.$a"; return 0; fi
  [ -f "$DIR/heal.off" ] || [ -f "$RUN/heal.pause.$a" ] && return 0
  [ -f "$RUN/seen.$a" ] || return 0            # never seen running since the daemon started: not ours to judge
  if [ -f "$RUN/tried.$a" ] && [ $((now - $(cat "$RUN/tried.$a"))) -lt "$HEAL_EVERY" ]; then return 0; fi
  n=$(docker exec hassio_cli ha apps info "$a" --raw-json 2>/dev/null | sed -n 's/^.*"data":{"name":"\([^"]*\)".*$/\1/p' | head -1)
  docker logs --since "$(cat "$RUN/seen.$a")" hassio_supervisor 2>&1 | grep -qE "Watchdog restart of app ${n:-$a} failed|$a has invalid options: Device|Watchdog restart of app $a failed" || return 0
  echo "$now" > "$RUN/tried.$a"
  if docker exec hassio_cli ha apps start "$a" >/dev/null 2>&1; then log "HEAL: $a was down after a watchdog failure -> started"
  else log "HEAL: $a still down (start failed; device missing?) -> retry in ${HEAL_EVERY}s"; fi
}
heals(){ [ -f "$HCONF" ] && grep -v '^[[:space:]]*#' "$HCONF" | awk 'NF>=1{print $1}'; }

each(){ grep -v '^[[:space:]]*#' "$CONF" | awk 'NF>=2{print $1}'; }

case "${1:-status}" in
  run)
    exec 9>"$RUN/lock"; flock -n 9 || { log "already running"; exit 0; }
    log "daemon start (grace ${GRACE}s, check ${CHECK}s, valve >${PSI_LIFT}% for ${BACKOFF}s)"
    while true; do
      for c in $(each); do valve "$c"; apply "$c"; done
      for a in $(heals); do heal "$a"; done
      sleep "$CHECK"
    done ;;
  apply-now) GRACE=0; for c in $(each); do apply "$c"; done ;;
  status)
    for c in $(each); do d=$(cg "$c") || { echo "$c: not running"; continue; }
      h=$(cat "$d/memory.high"); [ "$h" != max ] && h="$((h / 1048576))M"
      echo "$c: high=$h current=$(( $(cat "$d/memory.current") / 1048576 ))M want=$(mb_for "$c")M psi=$(awk '/^some/{print $3}' "$d/memory.pressure")$( [ -f "$RUN/backoff.$c" ] && echo " backoff-until=$(cat "$RUN/backoff.$c")")"
    done
    for a in $(heals); do echo "heal $a: running=$(docker inspect -f '{{.State.Running}}' "app_$a" 2>/dev/null || echo absent)$( [ -f "$RUN/heal.pause.$a" ] && echo ' PAUSED')"; done
    pgrep -f "haos-caps.sh run" >/dev/null && echo "daemon: running" || echo "daemon: NOT running" ;;
  undo)
    pkill -f "haos-caps.sh run" 2>/dev/null
    for c in $(each); do d=$(cg "$c") && echo max > "$d/memory.high"; done
    log "undo: daemon stopped, all caps -> max"; echo "undone" ;;
  *) echo "usage: $0 run|apply-now|status|undo"; exit 2 ;;
esac
