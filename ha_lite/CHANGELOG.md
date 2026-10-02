# Changelog
## 0.1.0
- First version: image swap with digest pinning, health check and rollback; host memory caps with pressure valve;
  restart after Supervisor watchdog failure; revert_all.

## 0.1.1
- Fix: run.sh gets the Supervisor token (with-contenv).

## 0.1.2
- Sets the Supervisor job option ignore_conditions=supervisor_updated when it pins the Supervisor (a pinned Supervisor
  blocks the add-on store); revert_all removes it.
- Skips a part when the data disk has less than 2 GB free.
- Clearer dry-run messages (says when the official image is already saved as -orig).

## 0.1.3
- Pin the Supervisor build (2026.09.2, Python 3.15 + lazy imports + dbus-fast 5.0.24, lazy on by default).
