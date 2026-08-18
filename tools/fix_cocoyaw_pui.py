#!/usr/bin/env python3
"""Patch the CocoYaw v5 pui-port without rewriting the resolver core."""

from __future__ import annotations

import argparse
from pathlib import Path


HELPERS = r'''
-- pui compatibility helpers -------------------------------------------------
-- pui.reference returns false when a GameSense path is misspelled. Every call
-- below treats that as "feature unavailable" instead of indexing the boolean
-- and exploding inside pui.
function fn.ui_get(item)
    if item == nil or item == false then return nil end
    if item.get then
        local ok, v = pcall(function() return item:get() end)
        if ok then return v end
    end
    return item.value
end

function fn.ui_enabled(item)
    local v = fn.ui_get(item)
    return v == true or v == 1
end

function fn.ui_hotkey(item)
    if item == nil or item == false then return false end
    if item.get_hotkey then
        local ok, v = pcall(function() return item:get_hotkey() end)
        if ok then return v == true end
    end
    if item.hotkey and item.hotkey.get then
        local ok, v = pcall(function() return item.hotkey:get() end)
        if ok then return v == true end
    end
    return false
end

function fn.ui_override(item, value)
    if item ~= nil and item ~= false and item.override then item:override(value) end
end

function fn.ui_override_hotkey(item, value)
    if item ~= nil and item ~= false and item.hotkey and item.hotkey.override then
        item.hotkey:override(value)
    end
end

function fn.ui_visible(item, value)
    if item ~= nil and item ~= false and item.set_visible then item:set_visible(value) end
end

function fn.dep_any(item, ...)
    local allowed = {...}
    return function()
        local v = item:get()
        for i = 1, #allowed do
            if v == allowed[i] then return true end
        end
        return false
    end
end
'''


MENU_HIDE = r'''function fn.menu_hide(value)
    fn.ui_visible(ref.aa_enabled, value)
    fn.ui_visible(ref.pitch[1], value)
    fn.ui_visible(ref.roll[1], value)
    fn.ui_visible(ref.yawbase, value)
    fn.ui_visible(ref.yaw[1], value)
    fn.ui_visible(ref.fsbodyyaw, value)
    fn.ui_visible(ref.yawjitter[1], value)
    fn.ui_visible(ref.bodyyaw[1], value)
    fn.ui_visible(ref.freestand[1], value)
    fn.ui_visible(ref.edgeyaw, value)
    fn.ui_visible(ref.pitch[2], value)
    fn.ui_visible(ref.yaw[2], value)
    fn.ui_visible(ref.yawjitter[2], value)
    fn.ui_visible(ref.bodyyaw[2], value)
end'''


RAW_MENU_HIDE = r'''function fn.menu_hide(value)
    ref.aa_enabled:set_visible(value)
    ref.pitch[1]:set_visible(value)
    ref.roll[1]:set_visible(value)
    ref.yawbase:set_visible(value)
    ref.yaw[1]:set_visible(value)
    ref.fsbodyyaw:set_visible(value)
    ref.yawjitter[1]:set_visible(value)
    ref.bodyyaw[1]:set_visible(value)
    ref.freestand[1]:set_visible(value)
    ref.edgeyaw:set_visible(value)
    if ref.pitch[2] then ref.pitch[2]:set_visible(value) end
    if ref.yaw[2] then ref.yaw[2]:set_visible(value) end
    if ref.yawjitter[2] then ref.yawjitter[2]:set_visible(value) end
    if ref.bodyyaw[2] then ref.bodyyaw[2]:set_visible(value) end
end'''


REPLACEMENTS = {
    "libs.pui.reference('AA', 'Anti-aimbot angles', 'Yaw base')":
        "libs.pui.reference('AA', 'Anti-aimbot angles', 'Yaw Base')",
    "libs.pui.reference('AA', 'Anti-aimbot angles', 'pitch')":
        "libs.pui.reference('AA', 'Anti-aimbot angles', 'Pitch')",
    "libs.pui.reference('AA', 'Anti-aimbot angles', 'Body yaw')":
        "libs.pui.reference('AA', 'Anti-aimbot angles', 'Body Yaw')",
    'libs.pui.reference("Players", "Adjustments", "Force body yaw")':
        'libs.pui.reference("Players", "Adjustments", "Force Body Yaw")',

    "{antiaims[i].desync_type, 'Jitter', 'Static'}":
        "{antiaims[i].desync_type, fn.dep_any(antiaims[i].desync_type, 'Jitter', 'Static')}",
    "{antiaims[i].yaw, 'Static', 'Switch'}":
        "{antiaims[i].yaw, fn.dep_any(antiaims[i].yaw, 'Static', 'Switch')}",
    "{antiaims[i].def_pitch, 'Custom', '3-Way', '5-Way'}":
        "{antiaims[i].def_pitch, fn.dep_any(antiaims[i].def_pitch, 'Custom', '3-Way', '5-Way')}",
    "{antiaims[i].def_pitch, 'Switch', '3-Way', '5-Way', 'Vladick', 'Spin'}":
        "{antiaims[i].def_pitch, fn.dep_any(antiaims[i].def_pitch, 'Switch', '3-Way', '5-Way', 'Vladick', 'Spin')}",
    "{antiaims[i].def_yaw, 'Static', '3-Way', '5-Way'}":
        "{antiaims[i].def_yaw, fn.dep_any(antiaims[i].def_yaw, 'Static', '3-Way', '5-Way')}",
    "{antiaims[i].def_yaw, 'Switch', '3-Way', '5-Way', 'Vladick', 'Spin'}":
        "{antiaims[i].def_yaw, fn.dep_any(antiaims[i].def_yaw, 'Switch', '3-Way', '5-Way', 'Vladick', 'Spin')}",
    "{antiaims[i].def_yaw, 'Jitter', 'Static'}":
        "{antiaims[i].def_yaw, fn.dep_any(antiaims[i].def_yaw, 'Jitter', 'Static')}",
    "{luaUi.visuals.watermark_type, 'Modern', 'Minimalistic'}":
        "{luaUi.visuals.watermark_type, fn.dep_any(luaUi.visuals.watermark_type, 'Modern', 'Minimalistic')}",

    "if luaUi.ragebot.hideshot_fix:get() and ref.os.value and ref.os.hotkey:get() then":
        "if luaUi.ragebot.hideshot_fix:get() and fn.ui_enabled(ref.os) and fn.ui_hotkey(ref.os) then",
    "if ref.os and ref.os.hotkey and ref.os.hotkey:get() then mg.exploit = \"HS\"; mg.DTHS = 1 end":
        "if fn.ui_enabled(ref.os) and fn.ui_hotkey(ref.os) then mg.exploit = \"HS\"; mg.DTHS = 1 end",
    "if ref.dt[1]:get_hotkey() then mg.exploit = \"DT\"; mg.DTHS = mg.DTHS + 1 end":
        "if fn.ui_hotkey(ref.dt[1]) then mg.exploit = \"DT\"; mg.DTHS = mg.DTHS + 1 end",
    "if not ref.dt[1]:get_hotkey() then return end":
        "if not fn.ui_hotkey(ref.dt[1]) then return end",
    "if want_ext and ref.dt[1]:get_hotkey() then":
        "if want_ext and fn.ui_hotkey(ref.dt[1]) then",
    "if ref.fakeduck:get_hotkey() then return false end":
        "if fn.ui_hotkey(ref.fakeduck) then return false end",
    "if ref.fakeduck:get_hotkey() then score = score + 25 end":
        "if fn.ui_hotkey(ref.fakeduck) then score = score + 25 end",
    "if ref.autopeek[1]:get_hotkey() then score = score - 35 end":
        "if fn.ui_hotkey(ref.autopeek[1]) then score = score - 35 end",
    "ref.freestand[1].hotkey:override({\"Always on\", 0})":
        "fn.ui_override_hotkey(ref.freestand[1], {\"Always on\", 0})",
    "else ref.freestand[1]:override(false) end":
        "else fn.ui_override(ref.freestand[1], false) end",
    "if yaw_direction ~= 0 then ref.freestand[1]:override(false) end":
        "if yaw_direction ~= 0 then fn.ui_override(ref.freestand[1], false) end",

    "h.g[#h.g+1] = {yaw=rv.y, off=off, st=st, t=now, hs=hs, stg=bidx}":
        "h.g[#h.g+1] = {yaw=rv.y, off=off, st=st, t=g_realtime(), hs=hs, stg=bidx}",
    "return m_random(mn, mx)":
        "return (client.random_float and client.random_float(mn, mx)) or (mn + math.random() * (mx - mn))",
    "aam.jitter = (aam.switch and -1 or 1) * m_random(aa.jit_max:get(), aa.jit_min:get())":
        "local j1, j2 = aa.jit_min:get(), aa.jit_max:get()\n    aam.jitter = (aam.switch and -1 or 1) * m_random(m_min(j1, j2), m_max(j1, j2))",
    "client.latency(0)/TICK_IV":
        "(client.latency() or 0)/TICK_IV",
    "ref.yaw[1]:override('Off'); ref.pitch[1]:override('Off'); return":
        "fn.ui_override(ref.yaw[1], 'Off'); fn.ui_override(ref.pitch[1], 'Off'); return",
}


AUTO_OSAA_RELEASES = {
    "if wn == 'CWeaponTaser' or wn == 'CKnife' then ref.os.hotkey:override(); ref.os:override(); ref.dt[1]:override(); return end":
        "if wn == 'CWeaponTaser' or wn == 'CKnife' then fn.ui_override_hotkey(ref.os); fn.ui_override(ref.os); fn.ui_override(ref.dt[1]); return end",
    "then ref.os.hotkey:override(); ref.os:override(); ref.dt[1]:override(); return end":
        "then fn.ui_override_hotkey(ref.os); fn.ui_override(ref.os); fn.ui_override(ref.dt[1]); return end",
    "ref.os.hotkey:override({\"Always on\", 0}); ref.os:override(true); ref.dt[1]:override(false)":
        "fn.ui_override_hotkey(ref.os, {\"Always on\", 0}); fn.ui_override(ref.os, true); fn.ui_override(ref.dt[1], false)",
    "else ref.os.hotkey:override(); ref.os:override(); ref.dt[1]:override() end":
        "else fn.ui_override_hotkey(ref.os); fn.ui_override(ref.os); fn.ui_override(ref.dt[1]) end",
}


VALIDATION_PATTERNS = [
    "libs.pui.reference('AA', 'Anti-aimbot angles', 'Yaw base')",
    "libs.pui.reference('AA', 'Anti-aimbot angles', 'pitch')",
    "libs.pui.reference('AA', 'Anti-aimbot angles', 'Body yaw')",
    'libs.pui.reference("Players", "Adjustments", "Force body yaw")',
    "ref.os.value",
    "client.latency(0)",
    "t=now",
    "{antiaims[i].desync_type, 'Jitter', 'Static'}",
    "{antiaims[i].yaw, 'Static', 'Switch'}",
    "{luaUi.visuals.watermark_type, 'Modern', 'Minimalistic'}",
]


def patch_source(source: str) -> str:
    source = source.replace(RAW_MENU_HIDE, MENU_HIDE)

    if "function fn.ui_hotkey(item)" not in source:
        marker = "-- hide GS built-in AA to avoid conflicts"
        source = source.replace(marker, HELPERS + "\n" + marker, 1)

    for old, new in REPLACEMENTS.items():
        source = source.replace(old, new)
    for old, new in AUTO_OSAA_RELEASES.items():
        source = source.replace(old, new)

    source = source.replace(
        "fn.anti_aim_setup(cmd)\n    fn.run_direction()",
        "fn.run_direction()\n    fn.anti_aim_setup(cmd)",
    )
    source = source.replace(
        "if luaUi.ragebot.auto_hide_shots:get() then fn.auto_osaa(cmd) end",
        "fn.auto_osaa(cmd)",
    )
    source = source.replace(
        "local raw = ref.minimum_damage_override[1]:get_hotkey() and ref.minimum_damage_override[2].value or ref.minimum_damage.value",
        "local raw = fn.ui_hotkey(ref.minimum_damage_override[1]) and (fn.ui_get(ref.minimum_damage_override[2]) or fn.ui_get(ref.minimum_damage_override[1])) or fn.ui_get(ref.minimum_damage)",
    )
    source = source.replace(
        "local a = ref.minimum_damage_override[1]:get_hotkey() and 255 or 100",
        "local a = fn.ui_hotkey(ref.minimum_damage_override[1]) and 255 or 100",
    )
    source = source.replace(
        "if el:get('Min.Damage') and ref.minimum_damage_override[1]:get_hotkey() then renderer.indicator(ir,ig,ib,255, 'DMG: ', ref.minimum_damage_override[2].value) end",
        "if el:get('Min.Damage') and fn.ui_hotkey(ref.minimum_damage_override[1]) then renderer.indicator(ir,ig,ib,255, 'DMG: ', fn.ui_get(ref.minimum_damage_override[2]) or fn.ui_get(ref.minimum_damage_override[1]) or '?') end",
    )
    source = source.replace(
        "elseif el:get('Hide-Shots') and ref.os.hotkey:get() then renderer.indicator(ir,ig,ib,255, 'HS') end",
        "elseif el:get('Hide-Shots') and fn.ui_hotkey(ref.os) then renderer.indicator(ir,ig,ib,255, 'HS') end",
    )
    source = source.replace(
        "ref.os.hotkey:override(); ref.os:override()\n    ref.dt[1]:override(); ref.flEnabled[1]:override()",
        "fn.ui_override_hotkey(ref.os); fn.ui_override(ref.os)\n    fn.ui_override(ref.dt[1]); fn.ui_override(ref.flEnabled[1])",
    )

    return source


def validate(source: str) -> list[str]:
    return [pattern for pattern in VALIDATION_PATTERNS if pattern in source]


def main() -> int:
    parser = argparse.ArgumentParser(description="Fix CocoYaw v5 pui-port source.")
    parser.add_argument("input", type=Path, help="broken CocoYaw pui Lua file")
    parser.add_argument("-o", "--output", type=Path, help="fixed output path")
    parser.add_argument("--check", action="store_true", help="fail if known broken patterns remain")
    args = parser.parse_args()

    source = args.input.read_text(encoding="utf-8")
    fixed = patch_source(source)
    leftovers = validate(fixed)
    if leftovers:
        for pattern in leftovers:
            print(f"leftover broken pattern: {pattern}")
        if args.check:
            return 1

    output = args.output or args.input
    output.write_text(fixed, encoding="utf-8")
    print(f"patched {args.input} -> {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
