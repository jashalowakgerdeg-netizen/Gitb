# CocoYaw fixed Lua build

This repo contains `cocoyaw.lua`, a fixed CocoYaw v5 GameSense Lua script with
the new tabbed UI, resolver, Hide-Shots/on-shot handling, adaptive hitscale,
tickbase guard, animation breakers, visuals, logs, buybot, clantag, and utility
features wired through the documented GameSense Lua globals.

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
python3 -m unittest discover -s tests -v
```
