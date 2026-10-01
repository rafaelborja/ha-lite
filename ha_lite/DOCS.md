# HA Lite (experimental)

HA Lite lowers Home Assistant's memory use on small aarch64 installs (measured on a 2 GB Home Assistant OS VM).
It is a **one-shot installer**: it runs, swaps images, sets memory caps, checks health and exits. Nothing of it stays
in memory except a tiny shell daemon on the host.

## What it changes
| Part | What the HA Lite build is | Effect measured on an arm64 HAOS install |
|---|---|---|
| Core | Same HA release on Python 3.15 with PEP 810 lazy imports and generic import/docstring tuning, plus a few upstream-bound fixes (lazy camera stream deps, Matter cluster definitions on demand, recorder dialects, python-slugify fast path) | ~690 → ~460 MB RSS |
| Supervisor | Same release on Python 3.15 with lazy imports and a dbus-fast fix | ~110 → ~80 MB |
| Zigbee2MQTT, Z-Wave JS UI, Matter Server | Official app on a shared Node 24 built with pointer compression, JavaScript cleaned (no comments/source maps, ASCII) | ~470 → ~245 MB for the three |
| Memory caps | Soft caps (`memory.high`, never a hard limit) with a pressure valve that lifts a cap when the container stalls | turns idle memory into free memory |
| Restart after watchdog failure | Restarts an add-on the Supervisor gave up on (e.g. a USB radio that came back a few seconds late) | reliability |

Only images built for the **exact** installed version are used; anything else is left on the official image.
Every build is pinned by SHA-256 digest and built in public CI from the stock release.

## Before you start
- Take a full backup.
- **Protection mode must be off** for this add-on (it needs the Docker API). That gives it root on the host: read
  `run.sh` before you trust it.
- After **any** Core, Supervisor or add-on update the official image comes back: run HA Lite again. The
  Supervisor's auto-update is turned **off** (an update would silently undo HA Lite).

## Options
`core`, `supervisor`, `zigbee2mqtt`, `zwave_js_ui`, `matter_server`: which parts to swap. `memory_caps` and the
`cap_*_mb` values: soft caps per container (start from these, raise one if the log shows its valve firing).
`restart_after_watchdog_failure`: the healer. `dry_run` (on by default): only log what would change. `revert_all`: put every official image back, remove the caps, turn
Supervisor auto-update back on.

## How it rolls back
Each swap keeps the official image as `<tag>-orig`. If the health check fails (Core API down, fewer than 90 % of the
entities, an add-on not running after 90 s, the Supervisor not answering) it re-tags the official image and
restarts. `revert_all: true` does it for everything.

## Not in the add-on (host side)
See `docs/android-crosvm.md` for running HAOS in a VM on an Android phone (fixed VM size, no balloon, USB
re-attach, battery watch).
