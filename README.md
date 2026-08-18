# CocoYaw pui repair

This repo contains a source-to-source fixer for the broken CocoYaw v5 pui UI
port.

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
python3 -m unittest discover -s tests -v
```
