# HA Lite (experimental)

A Home Assistant add-on repository with one add-on, **HA Lite**: lower-memory builds of Core, Supervisor and the
Node add-ons for small aarch64 installs, plus soft memory caps. See [`ha_lite/DOCS.md`](ha_lite/DOCS.md).

Add this repository in Settings → Add-ons → Add-on store → ⋮ → Repositories:
`https://github.com/rafaelborja/ha-lite`

**Experimental.** It replaces official images under their own tags (the originals are kept as `<tag>-orig`) and
needs protection mode off. Take a backup first. Builds: Core/Supervisor from
[ha-python315-arm64](https://github.com/rafaelborja/ha-python315-arm64), Node add-ons from
[node-pointer-compression-arm64](https://github.com/rafaelborja/node-pointer-compression-arm64).

License: MIT.
