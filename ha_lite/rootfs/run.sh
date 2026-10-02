#!/usr/bin/with-contenv bashio
# HA Lite -- one-shot installer. Swaps verified lower-memory images in under the official tags (keeping the official
# image as <tag>-orig), checks health and rolls back on failure, installs the host memory-caps daemon, then exits.
# Run it again after any Core/add-on/Supervisor update: images without a matching HA Lite build are left alone.
set -u
MANIFEST=/ha-lite/artifacts.json
API=http://supervisor
TOKEN=${SUPERVISOR_TOKEN}
api(){ curl -fsS -X "${2:-GET}" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
         ${3:+-d "$3"} "$API$1"; }
log(){ bashio::log.info "$*"; }
warn(){ bashio::log.warning "$*"; }
opt(){ bashio::config "$1"; }

# Our own image, used for short privileged helpers on the host (the add-on itself stays unprivileged).
SELF=$(docker ps -q | xargs docker inspect --format '{{.Config.Hostname}} {{.Config.Image}}' \
       | awk -v h="$(hostname)" '$1==h{print $2; exit}')
[ -n "$SELF" ] || bashio::exit.nok "cannot find my own container image"
host(){ docker run --rm --privileged --pid=host --net=host "$SELF" nsenter -t 1 -m -u -i -n -p -- sh -c "$1"; }
to_host(){ # copy the host scripts + generated configs to /mnt/data/haos-caps
  docker run --rm -v /mnt/data/haos-caps:/dst -e CAPS="$1" -e HEAL="$2" "$SELF" sh -c \
    'cp /ha-lite/host/haos-caps.sh /ha-lite/host/99-haos-caps.rules /dst/ &&
     printf "%s\n" "$CAPS" > /dst/haos-caps.conf && printf "%s\n" "$HEAL" > /dst/haos-heal.conf'; }

img_id(){ docker image inspect --format '{{.Id}}' "$1" 2>/dev/null; }
container_for(){ # $1 image repo -> running container name (app_* or addon_*) using it
  docker ps --format '{{.Names}} {{.Image}}' | awk -v r="$1" '$2 ~ "^"r":" && $1 ~ /^(app|addon)_/{print $1; exit}'; }
entry(){ jq -r --arg k "$1" --arg f "$2" '.[$k][$f] // empty' "$MANIFEST"; }

# The add-on's /data is on the same partition as Docker's images (/mnt/data). Each image needs ~0.4-1 GB.
MIN_FREE_MB=${MIN_FREE_MB:-2048}
enough_disk(){ free=$(df -Pm /data | awk 'NR==2{print $4}')
  [ "${free:-0}" -ge "$MIN_FREE_MB" ] && return 0
  warn "$1: only ${free} MB free on the data disk (need $MIN_FREE_MB) - skipped. Delete old backups and run again."; return 1; }
# A pinned Supervisor blocks the add-on store ("supervisor needs to be updated first"). The supported way out is the
# Supervisor's own job option ignore_conditions=[supervisor_updated]; revert_all removes it again.
ignore_sup_update(){ # $1 add|remove
  cur=$(api /jobs/info | jq -c '.data.ignore_conditions // []') || { warn "cannot read job options"; return 1; }
  if [ "$1" = add ]; then new=$(echo "$cur" | jq -c '. + ["supervisor_updated"] | unique')
  else new=$(echo "$cur" | jq -c '. - ["supervisor_updated"]'); fi
  [ "$new" = "$cur" ] && return 0
  api /jobs/options POST "{\"ignore_conditions\": $new}" >/dev/null \
    && log "Supervisor job option ignore_conditions = $new" \
    || warn "could not set ignore_conditions (set it by hand: ha jobs options --ignore-conditions supervisor_updated)"; }
core_states(){ api /core/api/states 2>/dev/null | jq 'length' 2>/dev/null || echo 0; }
wait_core(){ i=0; while [ $i -lt 60 ]; do api /core/api/ >/dev/null 2>&1 && return 0; sleep 10; i=$((i+1)); done; return 1; }
wait_running(){ sleep 90; [ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "$1" 2>/dev/null)" = "true false" ]; }
wait_supervisor(){ i=0; while [ $i -lt 36 ]; do api /supervisor/ping >/dev/null 2>&1 && return 0; sleep 5; i=$((i+1)); done; return 1; }

# swap <name> <official repo> <version> <restart fn> <health fn>
swap(){
  name=$1 repo=$2 ver=$3 restart=$4 health=$5
  lite=$(entry "$name" lite); want=$(entry "$name" version)
  if [ -z "$lite" ] || [ "$lite" = TBD ]; then log "$name: no HA Lite build published yet - skipped"; return 0; fi
  if [ "$ver" != "$want" ]; then log "$name: installed $ver, HA Lite build is for $want - skipped (official stays)"; return 0; fi
  enough_disk "$name" || return 0
  log "$name: pulling $lite"
  docker pull -q "$lite" >/dev/null || { warn "$name: pull failed - skipped"; return 0; }
  [ "$(img_id "$repo:$ver")" = "$(img_id "$lite")" ] && { log "$name: already on HA Lite"; return 0; }
  if [ "$DRY" = 1 ]; then
    if [ -n "$(img_id "$repo:$ver-orig")" ]; then keep="the official image is already saved as $repo:$ver-orig"
    else keep="would save the official image as $repo:$ver-orig"; fi
    log "$name: DRY RUN - $keep; would put $lite on $repo:$ver and restart"; return 0
  fi
  [ -n "$(img_id "$repo:$ver-orig")" ] || docker tag "$repo:$ver" "$repo:$ver-orig"
  docker tag "$lite" "$repo:$ver"
  $restart
  if $health; then log "$name: HA Lite image running and healthy"
  else
    warn "$name: health check FAILED - rolling back to the official image"
    docker tag "$repo:$ver-orig" "$repo:$ver"; $restart; $health || warn "$name: still unhealthy after rollback, check it"
  fi
}

revert_all(){
  for k in core zigbee2mqtt zwave_js_ui matter_server supervisor; do
    repo=$(entry "$k" official); [ -n "$repo" ] || continue
    for t in $(docker images --format '{{.Repository}}:{{.Tag}}' | grep "^$repo:.*-orig$"); do
      docker tag "$t" "${t%-orig}"; log "reverted $k -> ${t%-orig}"
    done
  done
  host 'sh /mnt/data/haos-caps/haos-caps.sh undo 2>/dev/null; rm -f /etc/udev/rules.d/99-haos-caps.rules; rm -rf /mnt/data/haos-caps' || true
  api /core/rebuild POST >/dev/null || true
  for k in zigbee2mqtt zwave_js_ui matter_server; do
    c=$(container_for "$(entry "$k" official)"); [ -n "$c" ] && api "/addons/${c#*_}/restart" POST >/dev/null || true
  done
  api /supervisor/options POST '{"auto_update": true}' >/dev/null || true
  ignore_sup_update remove
  log "Reverted Core and the Node add-ons; Supervisor auto-update is back ON. Restart the host to finish the Supervisor."
}

DRY=0; bashio::config.true dry_run && DRY=1 && log "DRY RUN: nothing will be changed"
if bashio::config.true revert_all; then
  [ "$DRY" = 1 ] && { log "DRY RUN - would revert every <tag>-orig and remove the memory caps"; exit 0; }
  revert_all; exit 0
fi

machine=$(api /core/info | jq -r .data.machine)
log "machine $machine; manifest $(jq -r ._meta.release $MANIFEST)"

# --- Core
if bashio::config.true core; then
  repo=$(entry core official | sed "s/{machine}/$machine/"); ver=$(api /core/info | jq -r .data.version)
  BEFORE=$(core_states)
  core_restart(){ api /core/rebuild POST >/dev/null || true; }
  core_health(){ wait_core && sleep 60 && n=$(core_states) && [ "$n" -ge $((BEFORE * 9 / 10)) ] \
                 && log "core: $n states (before $BEFORE)"; }
  swap core "$repo" "$ver" core_restart core_health
fi

# --- Node add-ons
for k in zigbee2mqtt zwave_js_ui matter_server; do
  bashio::config.true "$k" || continue
  repo=$(entry "$k" official); c=$(container_for "$repo")
  [ -n "$c" ] || { log "$k: not installed/running - skipped"; continue; }
  ver=$(docker inspect -f '{{.Config.Image}}' "$c" | sed 's/.*://')
  slug=${c#*_}
  eval "${k}_restart(){ api /addons/$slug/restart POST >/dev/null || true; }"
  eval "${k}_health(){ wait_running $c; }"
  swap "$k" "$repo" "$ver" "${k}_restart" "${k}_health"
done

# --- Memory caps + healer (host daemon)
if bashio::config.true memory_caps; then
  caps="homeassistant $(opt cap_core_mb)"; heal=""
  for k in zigbee2mqtt zwave_js_ui matter_server; do
    c=$(container_for "$(entry "$k" official)"); [ -n "$c" ] || continue
    caps="$caps
$c $(opt cap_${k}_mb)"
  done
  if bashio::config.true restart_after_watchdog_failure; then
    for s in $(api /addons | jq -r '.data.addons[] | select(.state=="started") | .slug'); do
      [ "$(api /addons/$s/info | jq -r .data.watchdog)" = true ] && heal="$heal$s
"
    done
  fi
  if [ "$DRY" = 1 ]; then log "DRY RUN - would install memory caps: $(echo "$caps" | tr '\n' ';') healer: $(echo "$heal" | tr '\n' ' ')"
  else
  to_host "$caps" "$heal"
  host 'cp /mnt/data/haos-caps/99-haos-caps.rules /etc/udev/rules.d/ &&
        (sh /mnt/data/haos-caps/haos-caps.sh undo >/dev/null 2>&1; systemctl stop haos-caps 2>/dev/null; true) &&
        systemd-run --no-block --unit=haos-caps /bin/sh /mnt/data/haos-caps/haos-caps.sh run' \
    && log "memory caps installed: $(echo "$caps" | tr '\n' ';')" || warn "memory caps: install failed"
  fi
fi

# --- Supervisor (last: it restarts the Supervisor)
if bashio::config.true supervisor; then
  repo=$(entry supervisor official); ver=$(api /supervisor/info | jq -r .data.version)
  sup_restart(){ host 'systemctl restart haos-supervisor' || true; }
  sup_health(){ wait_supervisor; }
  if [ "$DRY" = 1 ]; then log "supervisor: DRY RUN - installed $ver, HA Lite build $(entry supervisor version) / $(entry supervisor lite); a real run also turns auto-update off and sets ignore_conditions=supervisor_updated"
  elif [ -n "$(entry supervisor lite | grep -v TBD)" ] && [ "$ver" = "$(entry supervisor version)" ]; then
    enough_disk supervisor || { log "done"; exit 0; }
    api /supervisor/options POST '{"auto_update": false}' >/dev/null \
      && log "supervisor: auto-update turned OFF (an update would bring the official image back; run HA Lite after updating)"
    ignore_sup_update add
    lite=$(entry supervisor lite); docker pull -q "$lite" >/dev/null || { warn "supervisor: pull failed"; exit 0; }
    if [ "$(img_id "$repo:latest")" != "$(img_id "$lite")" ]; then
      [ -n "$(img_id "$repo:latest-orig")" ] || docker tag "$repo:latest" "$repo:latest-orig"
      docker tag "$lite" "$repo:latest"
      log "supervisor: restarting on the HA Lite image (this add-on may lose its API session for a minute)"
      sup_restart
      if ! sup_health; then
        warn "supervisor: did not come back - rolling back"; docker tag "$repo:latest-orig" "$repo:latest"; sup_restart
      fi
    else log "supervisor: already on HA Lite"; fi
  else log "supervisor: no HA Lite build for $ver - skipped"; fi
fi
log "done"
