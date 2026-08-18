# CocoYaw fixed Lua build

This repo contains `cocoyaw.lua`, the full CocoYaw v5 GameSense Lua script with a
new tabbed UI, wired through the documented GameSense Lua globals. Every menu
option has a code path behind it (a dead-option regression check enforces this).

Ported systems:

- Resolver: FFI animstate reads, signal hierarchy (LBY / animstate / pose /
  evidence / inference), sway phase, movement constraint, jitter2, LBY timer,
  7 brute-force stages, learning that ignores non-resolver misses.
- Aim support: backtrack (auto-sniper LBY), baim-if-lethal, enemy freestanding,
  anti-backstab.
- Anti-aim builder per condition: yaw modes, yaw modifiers (Offset/Center/
  Random/3-Way/5-Way), jitter/sway/spin/slow-jitter, desync, body yaw, roll,
  defensive pitch/yaw modes (Switch/Spin/3-Way/5-Way/Vladick), fake lag modes +
  break lag compensation, flick exploit, head peek.
- Rage: request-arbitrated adaptive hitscale, spread guard, adaptive DT
  hitchance, auto DT mode, DT outcome learning, custom per-weapon hitchance
  override, better DT recharge, jump scout, fix auto peek, auto Hide-Shots.
- Break animations: all 19 options wired.
- Visuals: crosshair indicators, manual arrows, damage/defensive/velocity
  indicators, custom indicators, watermark, anim breakers.
- Utils: viewmodel changer, aspect ratio, thirdperson, fast ladder, console
  filter, clantag, trashtalk, buybot, config system (database + base64 +
  clipboard).
- Telemetry: per-shot snapshots, categorized miss statistics.

The repo also keeps a source-to-source fixer for the pasted broken pui port.

Run it against the pasted pui version:

```sh
python3 tools/fix_cocoyaw_pui.py broken_cocoyaw.lua -o cocoyaw.lua --check
```

What it fixes:

- invalid GameSense pui reference names that return `false` and trigger
  `[string "pui"]:0: attempt to index a boolean value`
- multi-value `:depend()` conditions rewritten into predicate dependencies
- Hide-Shots/on-shot access through safe pui helpers
- stale Auto Hide-Shots overrides when the feature is disabled
- manual direction order so AA sees the current key state
- `math.random()` float-bound crashes in yaw randomization
- stale `client.latency(0)` usage in clantag timing
- undefined `now` in resolver learning hit records

Checks:

```sh
pip install luaparser   # optional: enables the AST parse check
python3 -m unittest discover -s tests -v
```

The test suite parses `cocoyaw.lua` to an AST, verifies no break-animation menu
option is left without a code path, and asserts the ported systems are present.
