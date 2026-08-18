-- CocoYaw v5 - full resolver / anti-aim / exploit layer for GameSense
-- New tabbed UI, GameSense Lua API globals, every menu option wired to code.
--
-- Sections:
--   helpers / ffi / safe ui              general plumbing
--   override registry                    restore everything we switch off
--   menu                                 tabbed UI, no dead options
--   resolver (acquire/estimate/resolve)  reading over inference, 7 brute stages
--   backtrack / baim / freestanding      per-target aim support
--   anti-aim builder                     yaw/pitch/desync/fakelag/flick/headpeek
--   hitscale / DT auto / DT learning     request-arbitrated rage values
--   break animations                     all 19 layer/pose breaks
--   visuals / utils / config             indicators, viewmodel, database configs
--   telemetry                            per-shot snapshots, miss stats

local vector = require("vector")
local ffi = require("ffi")

local clipboard_ok, clipboard = pcall(require, "gamesense/clipboard")
if not clipboard_ok then clipboard = nil end
local base64_ok, base64 = pcall(require, "gamesense/base64")
if not base64_ok then base64 = nil end
local entity_lib_ok, entity_lib = pcall(require, "gamesense/entity")
if not entity_lib_ok then entity_lib = nil end

local lua_name, build, version = "cocoyaw", "private", "5.0"

-- ═══════════════════════════════════════════════════════════════════════════
--  Localized builtins
-- ═══════════════════════════════════════════════════════════════════════════
local m_sqrt, m_abs, m_floor, m_ceil = math.sqrt, math.abs, math.floor, math.ceil
local m_atan2, m_deg, m_rad, m_pi = math.atan2, math.deg, math.rad, math.pi
local m_random, m_min, m_max = math.random, math.min, math.max
local m_cos, m_sin, m_fmod = math.cos, math.sin, math.fmod
local b_band, b_lshift = bit.band, bit.lshift
local t_remove, t_insert, t_concat = table.remove, table.insert, table.concat
local s_format, s_upper, s_sub = string.format, string.upper, string.sub

local e_prop = entity.get_prop
local e_origin = entity.get_origin
local e_dormant = entity.is_dormant
local e_alive = entity.is_alive
local e_players = entity.get_players
local e_local = entity.get_local_player
local e_hitbox = entity.hitbox_position
local e_weapon = entity.get_player_weapon
local e_class = entity.get_classname
local e_setprop = entity.set_prop
local g_tick = globals.tickcount
local g_curtime = globals.curtime
local g_realtime = globals.realtime
local c_eye = client.eye_position
local c_trace_b = client.trace_bullet
local c_trace_l = client.trace_line
local c_threat = client.current_threat
local c_latency = client.latency
local p_set = plist.set

local TICK_IV = globals.tickinterval()
local TICK_INV = 1 / TICK_IV

-- cold/whole-script namespace: keeps the chunk under LuaJIT's 200-local cap
local fn = {}

-- ═══════════════════════════════════════════════════════════════════════════
--  Helpers
-- ═══════════════════════════════════════════════════════════════════════════
function fn.clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end
function fn.norm(a) return (a + 180) % 360 - 180 end
function fn.delta(a, b) return (a - b + 180) % 360 - 180 end
function fn.lerp(a, b, t) return a + (b - a) * t end
function fn.ticks(t) return m_floor(0.5 + t * TICK_INV) end
function fn.approach(name, value, speed) return name + (value - name) * globals.absoluteframetime() * speed end

function fn.wrap_pitch(pitch)
    pitch = pitch % 360
    while pitch > 89 or pitch < -89 do
        if pitch > 89 then pitch = 178 - pitch elseif pitch < -89 then pitch = -178 - pitch end
    end
    return pitch
end

function fn.map_val(x, imin, imax, omin, omax)
    if imax == imin then return omin end
    return omin + (x - imin) * (omax - omin) / (imax - imin)
end

function fn.randf(lo, hi)
    if hi < lo then lo, hi = hi, lo end
    if client.random_float then return client.random_float(lo, hi) end
    return lo + math.random() * (hi - lo)
end

function fn.randomize(val, pct)
    if not pct or pct == 0 then return val end
    return fn.randf(val - val * pct * 0.01, val + val * pct * 0.01)
end

function fn.contains(list, value)
    if type(list) ~= "table" then return false end
    for i = 1, #list do if list[i] == value then return true end end
    return false
end

function fn.color(...)
    local c = {r = 255, g = 255, b = 255, a = 255}
    local n = select("#", ...)
    if n == 0 or n > 4 then return c end
    local v = {...}
    for i = 1, n do if type(v[i]) ~= "number" then return c end end
    c.r = fn.clamp(v[1], 0, 255)
    c.g = fn.clamp(v[2] or c.r, 0, 255)
    c.b = fn.clamp(v[3] or c.g, 0, 255)
    c.a = fn.clamp(v[4] or 255, 0, 255)
    return c
end

function fn.rgba_hex(r, g, b, a)
    return s_format("%02x%02x%02x%02x", m_floor(r), m_floor(g), m_floor(b), m_floor(a or 255))
end

function fn.log_segments(parts)
    for i = 1, #parts do
        local p = parts[i]
        client.color_log(p[1].r, p[1].g, p[1].b, tostring(p[2]) .. (i == #parts and "\n" or "\0"))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  FFI: CCSGOPlayerAnimState via explicit byte offsets
-- ═══════════════════════════════════════════════════════════════════════════
ffi.cdef[[
    struct coco_layer_t {
        char pad_0000[20];
        uint32_t m_nOrder;
        uint32_t m_nSequence;
        float m_flPrevCycle;
        float m_flWeight;
        float m_flWeightDeltaRate;
        float m_flPlaybackRate;
        float m_flCycle;
        void *m_pOwner;
        char pad_0038[4];
    };
]]

local STATE_OFF, LAYER_OFF = 0x9960, 0x2990
local AS = {
    EYE_YAW = 0x078, PITCH = 0x07C, GOAL_FEET = 0x080, CUR_FEET = 0x084,
    LEAN_AMT = 0x090, DUCK_AMT = 0x0A4, SPEED_2D = 0x0EC,
    FEET_SPD_A = 0x0F8, FEET_SPD_B = 0x0FC,
    ON_GROUND = 0x108, HIT_GROUND = 0x109, HEAD_HEIGHT = 0x118, STOP_FULL = 0x11C,
    MAX_YAW = 0x334,
}
local AL = {STRIDE = 0x38, SEQUENCE = 0x18, PREV_CYCLE = 0x1C, WEIGHT = 0x20, PLAYBACK = 0x28, CYCLE = 0x2C}
local TY = {
    f = ffi.typeof("float*"), b = ffi.typeof("bool*"), u = ffi.typeof("uint32_t*"),
    c = ffi.typeof("char*"), cc = ffi.typeof("char**"), vt = ffi.typeof("void***"),
}
local cast = ffi.cast
function fn.ASF(base, off) return cast(TY.f, base + off)[0] end
function fn.ASB(base, off) return cast(TY.b, base + off)[0] end
function fn.ALF(base, off) return cast(TY.f, base + off)[0] end
function fn.ALFS(base, off, v) cast(TY.f, base + off)[0] = v end
function fn.ALI(base, off) return cast(TY.u, base + off)[0] end
function fn.ALIS(base, off, v) cast(TY.u, base + off)[0] = v end

local entlist
for _, dll in ipairs({"client_panorama.dll", "client.dll"}) do
    local ok, iface = pcall(client.create_interface, dll, "VClientEntityList003")
    if ok and iface ~= nil then entlist = iface; break end
end
if entlist == nil then error("VClientEntityList003 not found") end
local entlist_vt = cast(TY.vt, entlist)
local getent = cast(ffi.typeof("void*(__thiscall*)(void*, int)"), entlist_vt[0][3])

function fn.entptr(idx)
    if idx == nil then return nil end
    local ok, p = pcall(getent, entlist, idx)
    if ok then return p end
end

function fn.animbase(idx)
    local p = fn.entptr(idx)
    if p == nil then return nil end
    local ok, base = pcall(function()
        local s = cast(TY.cc, cast(TY.c, p) + STATE_OFF)[0]
        return s ~= nil and cast(TY.c, s) or nil
    end)
    return ok and base or nil
end

function fn.layerbase(idx, i)
    local p = fn.entptr(idx)
    if p == nil then return nil end
    local ok, base = pcall(function()
        local lp = cast(TY.cc, cast(TY.c, p) + LAYER_OFF)
        if lp == nil or lp[0] == nil then return nil end
        return cast(TY.c, lp[0]) + i * AL.STRIDE
    end)
    return ok and base or nil
end

local MAX_YAW_FALLBACK = 58
function fn.valid_angle(v) return type(v) == "number" and v == v and v >= -181 and v <= 181 end

function fn.max_desync(base)
    if base == nil then return nil end
    local ok, v = pcall(function()
        local duck, sfrac, sfact = fn.ASF(base, AS.DUCK_AMT), fn.ASF(base, AS.FEET_SPD_A), fn.ASF(base, AS.FEET_SPD_B)
        if duck ~= duck or sfrac ~= sfrac or sfact ~= sfact then return nil end
        if duck < -0.01 or duck > 1.01 or sfrac < -0.01 or sfrac > 1.5 or sfact < -0.01 or sfact > 1.5 then return nil end
        local maxy = fn.ASF(base, AS.MAX_YAW)
        if maxy ~= maxy or maxy < 45 or maxy > 62 then maxy = MAX_YAW_FALLBACK end
        local stfr = fn.ASF(base, AS.STOP_FULL)
        if stfr ~= stfr or stfr < -0.01 or stfr > 1.01 then stfr = fn.clamp(sfrac, 0, 1) end
        sfrac, sfact = fn.clamp(sfrac, 0, 1), fn.clamp(sfact, 0, 1)
        local m = (stfr * -0.30000001 - 0.19999999) * sfrac + 1
        if duck > 0 then m = m + duck * sfact * (0.5 - m) end
        return maxy * m
    end)
    if not ok or v == nil or v ~= v then return nil end
    v = m_abs(v)
    if v < 1 or v > 62 then return nil end
    return v
end

local PZ = {
    STRAFE_YAW = 0, STAND = 1, LEAN_YAW = 2, LADDER_YAW = 4, JUMP_FALL = 6,
    MOVE_YAW = 7, BLEND_CROUCH = 8, BLEND_WALK = 9, BLEND_RUN = 10, BODY_YAW = 11, BODY_PITCH = 12,
}
function fn.pose_body(ent)
    local p = e_prop(ent, "m_flPoseParameter", PZ.BODY_YAW)
    if type(p) ~= "number" then return nil end
    return fn.clamp(p * 120 - 60, -60, 60)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Safe UI reference wrappers - the whole point of the pui fix. A misspelled
--  built-in name returns false; every access below tolerates that instead of
--  indexing a boolean and throwing inside the menu framework.
-- ═══════════════════════════════════════════════════════════════════════════
function fn.refs(tab, container, name)
    local out = {pcall(ui.reference, tab, container, name)}
    if not out[1] then return {} end
    t_remove(out, 1)
    return out
end

function fn.get(ref, fallback)
    if ref == nil then return fallback end
    local ok, a, b, c, d = pcall(ui.get, ref)
    if ok then return a, b, c, d end
    return fallback
end

function fn.set(ref, ...) if ref ~= nil then pcall(ui.set, ref, ...) end end
function fn.vis(ref, value) if ref ~= nil then pcall(ui.set_visible, ref, value) end end

local ref = {
    AA = {
        enabled = fn.refs("AA", "Anti-aimbot angles", "Enabled")[1],
        pitch = fn.refs("AA", "Anti-aimbot angles", "Pitch"),
        yawbase = fn.refs("AA", "Anti-aimbot angles", "Yaw Base")[1],
        yaw = fn.refs("AA", "Anti-aimbot angles", "Yaw"),
        jitter = fn.refs("AA", "Anti-aimbot angles", "Yaw jitter"),
        bodyyaw = fn.refs("AA", "Anti-aimbot angles", "Body Yaw"),
        fsbodyyaw = fn.refs("AA", "Anti-aimbot angles", "Freestanding body yaw")[1],
        edgeyaw = fn.refs("AA", "Anti-aimbot angles", "Edge yaw")[1],
        freestand = fn.refs("AA", "Anti-aimbot angles", "Freestanding"),
        roll = fn.refs("AA", "Anti-aimbot angles", "Roll")[1],
    },
    FL = {
        enabled = fn.refs("AA", "Fake lag", "Enabled"),
        amount = fn.refs("AA", "Fake lag", "Amount")[1],
        variance = fn.refs("AA", "Fake lag", "Variance")[1],
        limit = fn.refs("AA", "Fake lag", "Limit")[1],
    },
    slow = fn.refs("AA", "Other", "Slow motion"),
    leg = fn.refs("AA", "Other", "Leg movement")[1],
    hideshots = fn.refs("AA", "Other", "On shot anti-aim"),
    fakeduck = fn.refs("RAGE", "Other", "Duck peek assist"),
    autopeek = fn.refs("RAGE", "Other", "Quick peek assist"),
    doubletap = fn.refs("RAGE", "Aimbot", "Double tap"),
    rage = fn.refs("RAGE", "Aimbot", "Enabled"),
    hitchance = fn.refs("RAGE", "Aimbot", "Minimum hit chance")[1],
    mindmg = fn.refs("RAGE", "Aimbot", "Minimum damage")[1],
    mindmg_override = fn.refs("RAGE", "Aimbot", "Minimum damage override"),
    mpscale = fn.refs("RAGE", "Aimbot", "Multi-point scale")[1],
    dthc = fn.refs("RAGE", "Aimbot", "Double tap hit chance")[1],
    wtype = fn.refs("RAGE", "Weapon type", "Weapon type")[1],
    forcebaim = fn.refs("RAGE", "Aimbot", "Force body aim")[1],
    safepoint = fn.refs("RAGE", "Aimbot", "Force safe point")[1],
    autostrafe = fn.refs("MISC", "Movement", "Air strafe")[1],
    clantag = fn.refs("Misc", "Miscellaneous", "Clan tag spammer")[1],
    ping_spike = fn.refs("Misc", "Miscellaneous", "Ping spike"),
    feature_inds = fn.refs("Visuals", "Other ESP", "Feature indicators")[1],
    player_reset = fn.refs("Players", "Players", "Reset All")[1],
    plist_force_body = fn.refs("Players", "Adjustments", "Force Body Yaw")[1],
    plist_corr = fn.refs("Players", "Adjustments", "Correction Active")[1],
}

-- Double tap mode combobox rides on the DT reference as an extra return; which
-- slot differs between builds, so read every return and keep the mode string.
local DT_MODE
do
    local r = {pcall(ui.reference, "RAGE", "Aimbot", "Double tap")}
    if r[1] then
        for i = 2, #r do
            local okv, v = pcall(ui.get, r[i])
            if okv and (v == "Offensive" or v == "Defensive") then DT_MODE = r[i]; break end
        end
    end
end

function fn.hotkey_active(hotkey_ref)
    -- built-in hotkeys are separate references that ui.get returns a boolean for
    if hotkey_ref == nil then return false end
    local v = fn.get(hotkey_ref, nil)
    return v == true
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Override registry - anything we switch off in the gamesense menu is recorded
--  and restored unconditionally at the top of the next tick.
-- ═══════════════════════════════════════════════════════════════════════════
local OVR = {}
function fn.ovr(r, ...)
    if r == nil then return end
    if OVR[r] == nil then OVR[r] = {fn.get(r)} end
    fn.set(r, ...)
end
function fn.restore()
    for r, prev in pairs(OVR) do fn.set(r, prev[1]); OVR[r] = nil end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Menu - one AA container, tabbed via comboboxes, visibility driven so no
--  control is ever shown without a code path behind it.
-- ═══════════════════════════════════════════════════════════════════════════
local TAB, CONT = "AA", "Anti-aimbot angles"
local tabs = {"Home", "Anti-Aims", "Ragebot", "Utils", "Visuals"}
local conditions = {"Shared", "Standing", "Running", "Walking", "Aerobic", "Aerobic+", "Ducking", "Sneaking"}
local CIDX = {Shared = 1, Standing = 2, Running = 3, Walking = 4, Aerobic = 5, ["Aerobic+"] = 6, Ducking = 7, Sneaking = 8}

-- display name: strip the "CY " tag, sentence-case (first upper, rest lower),
-- wrap in <--...-->. Kept as a plain local so fn.bt's callback param can't
-- shadow the fn table when this is called.
local function menu_name(raw)
    if type(raw) ~= "string" or raw:sub(1, 3) ~= "CY " then return raw end
    local s = raw:sub(4)
    if #s == 0 then return raw end
    return "<--" .. s:sub(1, 1):upper() .. s:sub(2):lower() .. "-->"
end

function fn.cb(name, ...) return ui.new_combobox(TAB, CONT, menu_name(name), ...) end
function fn.ck(name) return ui.new_checkbox(TAB, CONT, menu_name(name)) end
function fn.sl(name, ...) return ui.new_slider(TAB, CONT, menu_name(name), ...) end
function fn.ms(name, ...) return ui.new_multiselect(TAB, CONT, menu_name(name), ...) end
function fn.hk(name, inline) return ui.new_hotkey(TAB, CONT, menu_name(name), inline) end
function fn.bt(name, cbfn) return ui.new_button(TAB, CONT, menu_name(name), cbfn) end
function fn.lb(name) return ui.new_label(TAB, CONT, menu_name(name)) end

local ui_tab = fn.cb("CocoYaw", tabs)
local ui_sub = fn.cb("AA Page", "Builder", "Misc")
local ui_state = fn.cb("State", conditions)

local m = {}

-- Home
m.home = {
    title = fn.lb("CocoYaw v" .. version),
    subtitle = fn.lb("reading over inference"),
}

-- Anti-Aims / Misc
m.aa = {
    yaw_base = fn.cb("CY Yaw Base", "At targets", "Local view"),
    tweaks = fn.ms("CY Tweaks", "Anti Backstab", "Edge Yaw on FD", "Static on Manual", "Disable Roll on Auto Peek", "Static on TP/Recharge", "Micro Movement"),
    fl_active = fn.ck("CY Exploit Fake Lag"),
    fl_mode = fn.cb("CY FL Mode", "Static", "Adaptive", "Peek", "Random"),
    fl_limit = fn.sl("CY FL Limit", 1, 16, 14, true, "t"),
    fl_min = fn.sl("CY FL Minimum", 1, 16, 1, true, "t"),
    fl_breaklc = fn.ck("CY Break Lag Compensation"),
    fl_breakdist = fn.sl("CY Break Distance", 32, 128, 66, true, "u"),
    fl_breakcond = fn.ms("CY Break On", "Moving", "In Air", "Peeking", "Defensive"),
    fl_breakshot = fn.ck("CY Break Through Shots"),
    flick = fn.ck("CY Flick Exploit"),
    flick_type = fn.cb("CY Flick Mode", "Left", "Right", "Custom"),
    flick_value = fn.sl("CY Flick Value", -180, 180, 0, true, "d"),
    manual_left = fn.hk("CY Manual Left"),
    manual_right = fn.hk("CY Manual Right"),
    manual_forward = fn.hk("CY Manual Forward"),
    freestand = fn.hk("CY Freestanding"),
    desync_inverter = fn.hk("CY Desync Inverter"),
    body_jitter_type = fn.cb("CY Body Jitter Type", "Jitter Side", "Invert Jitter Side", "Desync", "Invert Jitter Desync"),
    head_peek_lean = fn.sl("CY Head Peek Lean", 0, 200, 100, true, "%", 0.01),
    head_peek_ceil = fn.ck("CY Head Peek Engine Ceiling"),
    defensive_risk = fn.cb("CY Defensive Risk", "High", "Medium", "Low", "Safest"),
    ext_def = fn.hk("CY Extended Defensive"),
    ext_def_hit = fn.hk("CY Ext. Def. on Hittable"),
    leg_breaker = fn.ck("CY Leg Breaker"),
    disablers = fn.ms("CY Disablers", "Disable on Warmup", "Disable on Round End"),
    tweak_aa = fn.ck("CY Break Animations"),
    tweak_opts = fn.ms("CY Animation Breaks",
        "Extreme body lean", "Lean jitter", "Speed scaled lean", "On-shot spike",
        "Freestand lean", "Defensive boost", "Air walk", "Earthquake", "Fake walk",
        "Moonwalk", "Smoothing", "Fallen legs", "Slide", "Fake duck", "Fake flash",
        "Break legs", "Break move yaw", "Air desync", "Land pitch break"),
    tweak_lean = fn.sl("CY Body Lean", 0, 1000, 100, true, "%", 0.01),
    tweak_defmul = fn.sl("CY Defensive Multiplier", 100, 400, 250, true, "%", 0.01),
}

-- Anti-Aims / Builder (per condition)
local aa = {}
for i = 1, #conditions do
    local c = conditions[i]
    aa[i] = {
        enabled = fn.ck("CY enable " .. c),
        pitch = fn.cb("CY pitch " .. c, "Off", "Default", "Up", "Down", "Minimal", "Random"),
        yaw_base = fn.cb("CY yaw base " .. c, "Local view", "At targets"),
        yaw = fn.cb("CY yaw " .. c, "Off", "Static", "Switch"),
        yaw_static = fn.sl("CY yaw value " .. c, -180, 180, 0, true, "d"),
        yaw_left = fn.sl("CY left value " .. c, -180, 180, 0, true, "d"),
        yaw_right = fn.sl("CY right value " .. c, -180, 180, 0, true, "d"),
        yaw_random = fn.sl("CY yaw random " .. c, 0, 100, 0, true, "%"),
        yaw_modifier = fn.cb("CY yaw modifier " .. c, "Off", "Offset", "Center", "Random", "3-Way", "5-Way"),
        yaw_modifier_value = fn.sl("CY modifier value " .. c, -180, 180, 0, true, "d"),
        yaw_modifier_random = fn.sl("CY modifier random " .. c, 0, 100, 0, true, "%"),
        mods = fn.ms("CY modifiers " .. c, "Jitter", "Sway", "Spin", "Slow Jitter"),
        jit_min = fn.sl("CY jitter min " .. c, -90, 90, 0, true, "d"),
        jit_max = fn.sl("CY jitter max " .. c, -90, 90, 0, true, "d"),
        jit_delaymin = fn.sl("CY jitter delay min " .. c, 0, 5, 0, true, "t"),
        jit_delaymax = fn.sl("CY jitter delay max " .. c, 0, 5, 0, true, "t"),
        sway_amount = fn.sl("CY sway amount " .. c, 0, 90, 0, true, "d"),
        sway_speed = fn.sl("CY sway speed " .. c, 0, 30, 0),
        spin_amount = fn.sl("CY spin amount " .. c, 0, 360, 0, true, "d"),
        spin_speed = fn.sl("CY spin speed " .. c, 0, 30, 0),
        slow_amount = fn.sl("CY slow jitter amount " .. c, 0, 90, 45, true, "d"),
        slow_period = fn.sl("CY slow jitter period " .. c, 2, 8, 3),
        desync = fn.cb("CY desync " .. c, "Off", "Jitter", "Static"),
        desync_amount = fn.sl("CY desync amount " .. c, 0, 120, 60, true, "d"),
        bodyyaw = fn.ck("CY body yaw " .. c),
        body_jitter = fn.ck("CY body jitter " .. c),
        roll = fn.sl("CY roll " .. c, -45, 45, 0, true, "d"),
        fs_bodyyaw = fn.ck("CY freestanding body yaw " .. c),
        defensive = fn.ck("CY defensive " .. c),
        force_def = fn.ck("CY force defensive " .. c),
        def_pitch = fn.cb("CY def pitch " .. c, "Off", "Up", "Down", "Zero", "Random", "Switch", "Spin", "3-Way", "5-Way", "Vladick", "Custom"),
        def_pitch_value = fn.sl("CY def pitch value " .. c, -89, 89, 0, true, "d"),
        def_pitch_jit1 = fn.sl("CY def pitch first " .. c, -89, 89, 0, true, "d"),
        def_pitch_jit2 = fn.sl("CY def pitch second " .. c, -89, 89, 0, true, "d"),
        def_pitch_spin = fn.sl("CY def pitch spin " .. c, 1, 10, 1),
        def_pitch_random = fn.sl("CY def pitch random " .. c, 0, 100, 0, true, "%"),
        def_yaw = fn.cb("CY def yaw " .. c, "Off", "Static", "Switch", "Forward", "Opposite", "Jitter", "Spin", "3-Way", "5-Way", "Vladick"),
        def_yaw_value = fn.sl("CY def yaw value " .. c, -180, 180, 0, true, "d"),
        def_yaw_left = fn.sl("CY def yaw left " .. c, -180, 180, 0, true, "d"),
        def_yaw_right = fn.sl("CY def yaw right " .. c, -180, 180, 0, true, "d"),
        def_yaw_spin = fn.sl("CY def yaw spin " .. c, 1, 10, 1),
        def_yaw_random = fn.sl("CY def yaw random " .. c, 0, 100, 0, true, "%"),
        def_amount = fn.sl("CY def amount " .. c, 0, 180, 90, true, "d"),
    }
end
fn.set(aa[1].enabled, true)

-- Ragebot
m.rage = {
    resolver = fn.ck("CY Enable Resolver"),
    onshot = fn.ck("CY On-shot Angle Capture"),
    maxdes = fn.ck("CY Engine Desync Ceiling"),
    pgate = fn.ck("CY Pitch Gate (skip non-AA)"),
    pose = fn.ck("CY Pose Parameter Fallback"),
    hs = fn.ck("CY Adaptive Hitscale"),
    hs_dmg = fn.ck("CY Adaptive Lethal Damage"),
    spread = fn.ck("CY Spread Guard"),
    spread_strength = fn.sl("CY Spread Guard Strength", 0, 200, 100, true, "%"),
    dt_auto = fn.ck("CY Auto DT Mode"),
    dt_auto_deadband = fn.sl("CY DT Switch Deadband", 4, 40, 12),
    dthc = fn.ck("CY Adaptive DT Hitchance"),
    dthc_off = fn.sl("CY DT HC Offensive", 0, 100, 30, true, "%"),
    dthc_def = fn.sl("CY DT HC Defensive", 0, 100, 55, true, "%"),
    dthc_uncharged = fn.sl("CY DT Uncharged Penalty", 0, 100, 40, true, "%"),
    dthc_learn = fn.ck("CY DT Outcome Learning"),
    dt_recharge = fn.ck("CY Better DT Recharge"),
    fix_autopeek = fn.ck("CY Fix Auto Peek"),
    jump_scout = fn.ck("CY Jump Scout"),
    scout_hc = fn.sl("CY Scout HC", 0, 100, 75, true, "%"),
    jump_hc = fn.sl("CY Jump HC", 0, 100, 40, true, "%"),
    auto_hs = fn.ck("CY Auto Hide-Shots"),
    auto_hs_wep = fn.ms("CY HS Disable Weapons", "Scout", "AWP", "Auto", "Deagle & R8"),
    auto_hs_state = fn.ms("CY HS States", "Standing", "Walking", "Crouching", "Sneaking"),
    override_hc = fn.ck("CY Override Hitchance"),
    ovr_hc_wep = fn.ms("CY HC Weapons", "Scout", "AWP", "Auto", "R8"),
    ovr_scout_hc = fn.sl("CY Scout Hitchance", 0, 100, 0, true, "%"),
    ovr_awp_hc = fn.sl("CY AWP Hitchance", 0, 100, 0, true, "%"),
    ovr_auto_hc = fn.sl("CY Auto Hitchance", 0, 100, 0, true, "%"),
    ovr_r8_hc = fn.sl("CY R8 Hitchance", 0, 100, 0, true, "%"),
    hideshot_fix = fn.ck("CY Hide-Shots Fix"),
}

-- Utils
m.utils = {
    logs = fn.ck("CY Aimbot Logs"),
    log_types = fn.ms("CY Log Type", "Hit", "Miss"),
    miss_logs = fn.ck("CY Full Miss Logs"),
    miss_dump = fn.hk("CY Dump Miss Stats", true),
    buybot = fn.ck("CY BuyBot"),
    primary = fn.cb("CY Primary", " ", "awp", "ssg08", "scar20", "g3sg1", "galilar", "mag7", "ak47", "m4a1", "m4a1_silencer", "aug", "famas", "sg556"),
    pistol = fn.cb("CY Pistol", " ", "deagle", "elite", "tec9", "p250", "fn57"),
    nade = fn.ms("CY Nade", "molotov", "hegrenade", "smokegrenade", "decoy", "flashbang"),
    extra = fn.ms("CY Extra", "vesthelm", "taser", "defuser", "vest"),
    clantag = fn.ck("CY Clan-Tag Spammer"),
    trashtalk = fn.ck("CY Trashtalk"),
    fast_ladder = fn.ck("CY Fast Ladder"),
    console_filter = fn.ck("CY Console Filter"),
    thirdperson = fn.ck("CY Thirdperson Distance"),
    thirdperson_dist = fn.sl("CY Distance", 25, 230, 150, true, "u"),
    aspect = fn.ck("CY Aspect Ratio"),
    aspect_value = fn.sl("CY Aspect Value", 0, 200, 0, true, "x", 0.01),
    vm_changer = fn.ck("CY Viewmodel Changer"),
    vm_fov = fn.sl("CY Viewmodel FOV", 0, 100, 68, true, "d"),
    vm_x = fn.sl("CY Viewmodel X", -20, 20, 2),
    vm_y = fn.sl("CY Viewmodel Y", -20, 20, 0),
    vm_z = fn.sl("CY Viewmodel Z", -20, 20, -1),
    vm_opposite = fn.ck("CY Opposite Hands"),
    vm_opposite_knife = fn.ck("CY Opposite Knife"),
}

-- Visuals
m.vis = {
    indicators = fn.ck("CY Crosshair Indicators"),
    ind_color = ui.new_color_picker(TAB, CONT, menu_name("CY Indicator Color"), 250, 200, 140, 255),
    ind_elements = fn.ms("CY Indicator Elements", "Branch", "State", "Desync Side", "Hotkeys"),
    ind_gradient = fn.ck("CY Indicator Gradient"),
    arrows = fn.ck("CY Manual Arrows"),
    arrows_type = fn.cb("CY Arrows Type", "TeamSkeet", "Old School", "Modern"),
    arrows_velocity = fn.ck("CY Arrows Velocity Based"),
    damage = fn.ck("CY Damage Indicator"),
    velocity_warning = fn.ck("CY Velocity Warning"),
    defensive_ind = fn.ck("CY Defensive Indication"),
    custom_inds = fn.ck("CY Custom Indicators"),
    custom_inds_elements = fn.ms("CY Custom Elements", "Force safe point", "Force baim", "Ping spike", "Double tap", "Fake Duck", "Freestanding", "Hide-Shots", "Min.Damage", "Hitchance Override"),
    anim_breaker = fn.ck("CY Anim Breakers"),
    anim_air = fn.cb("CY Anim In Air", "Off", "Static", "Fipp"),
    anim_land = fn.cb("CY Anim On Land", "Off", "Static", "Walking", "Fipp"),
    anim_additions = fn.ms("CY Anim Additions", "Pitch 0 on Land", "Move Lean"),
    watermark = fn.ck("CY Watermark"),
    watermark_type = fn.cb("CY Watermark Type", "Modern", "Minimalistic", "Supremacy"),
    watermark_pos = fn.cb("CY Watermark Position", "Bottom", "Left", "Right"),
    watermark_color = ui.new_color_picker(TAB, CONT, menu_name("CY Watermark Color"), 250, 200, 140, 255),
}

-- config listbox + buttons
local CONFIG_KEY = "configs.cocoyaw.v5"
local default_config = {n = {"Default"}, cfg = {""}}
if database and database.read(CONFIG_KEY) == nil then database.write(CONFIG_KEY, json.stringify(default_config)) end
local config_data = (database and json.parse(database.read(CONFIG_KEY))) or default_config
if type(config_data) ~= "table" or type(config_data.n) ~= "table" then config_data = default_config end

m.cfg = {
    list = ui.new_listbox(TAB, CONT, menu_name("CY Config List"), config_data.n),
    name = ui.new_textbox(TAB, CONT, menu_name("CY Config Name")),
}

-- defaults on
fn.set(m.rage.resolver, true); fn.set(m.rage.onshot, true); fn.set(m.rage.maxdes, true)
fn.set(m.rage.pgate, true); fn.set(m.rage.pose, true); fn.set(m.rage.spread, true)
fn.set(m.vis.indicators, true); fn.set(m.vis.watermark, true)

-- ═══════════════════════════════════════════════════════════════════════════
--  Menu visibility - single source of truth, driven by the tab comboboxes.
-- ═══════════════════════════════════════════════════════════════════════════
function fn.all_items()
    local list = {}
    local function push(t) for _, v in pairs(t) do if type(v) == "number" then list[#list + 1] = v end end end
    for _, group in pairs(m) do push(group) end
    for i = 1, #aa do push(aa[i]) end
    return list
end
local ITEMS = fn.all_items()

function fn.menu_hide_builtin(value)
    fn.vis(ref.AA.enabled, value); fn.vis(ref.AA.yawbase, value); fn.vis(ref.AA.fsbodyyaw, value)
    fn.vis(ref.AA.edgeyaw, value); fn.vis(ref.AA.roll, value)
    for _, v in ipairs(ref.AA.pitch) do fn.vis(v, value) end
    for _, v in ipairs(ref.AA.yaw) do fn.vis(v, value) end
    for _, v in ipairs(ref.AA.jitter) do fn.vis(v, value) end
    for _, v in ipairs(ref.AA.bodyyaw) do fn.vis(v, value) end
    for _, v in ipairs(ref.AA.freestand) do fn.vis(v, value) end
    for _, v in ipairs(ref.FL.enabled) do fn.vis(v, value) end
    fn.vis(ref.FL.amount, value); fn.vis(ref.FL.variance, value); fn.vis(ref.FL.limit, value)
end

function fn.refresh_menu()
    for i = 1, #ITEMS do fn.vis(ITEMS[i], false) end
    -- ui_tab/ui_sub/ui_state are standalone controls, not part of ITEMS, so they
    -- must be driven here or they leak into every tab
    fn.vis(ui_tab, true)
    fn.vis(ui_sub, false)
    fn.vis(ui_state, false)
    local tab = fn.get(ui_tab, "Home")

    if tab == "Home" then
        fn.vis(m.home.title, true); fn.vis(m.home.subtitle, true)
        fn.vis(m.cfg.list, true); fn.vis(m.cfg.name, true)
        for _, b in ipairs(m.cfg_buttons or {}) do fn.vis(b, true) end

    elseif tab == "Anti-Aims" then
        fn.vis(ui_sub, true)
        local page = fn.get(ui_sub, "Builder")
        if page == "Misc" then
            local a = m.aa
            for _, v in pairs(a) do fn.vis(v, true) end
            fn.vis(a.fl_mode, fn.get(a.fl_active))
            fn.vis(a.fl_limit, fn.get(a.fl_active))
            fn.vis(a.fl_min, fn.get(a.fl_active) and (fn.get(a.fl_mode) == "Random" or fn.get(a.fl_mode) == "Adaptive"))
            fn.vis(a.fl_breaklc, fn.get(a.fl_active))
            local brk = fn.get(a.fl_active) and fn.get(a.fl_breaklc)
            fn.vis(a.fl_breakdist, brk); fn.vis(a.fl_breakcond, brk); fn.vis(a.fl_breakshot, brk)
            fn.vis(a.flick_type, fn.get(a.flick))
            fn.vis(a.flick_value, fn.get(a.flick) and fn.get(a.flick_type) == "Custom")
            fn.vis(a.head_peek_lean, fn.get(a.body_jitter_type) == "Invert Jitter Desync")
            fn.vis(a.head_peek_ceil, fn.get(a.body_jitter_type) == "Invert Jitter Desync")
            fn.vis(a.tweak_opts, fn.get(a.tweak_aa))
            fn.vis(a.tweak_lean, fn.get(a.tweak_aa) and fn.contains(fn.get(a.tweak_opts, {}), "Extreme body lean"))
            fn.vis(a.tweak_defmul, fn.get(a.tweak_aa) and fn.contains(fn.get(a.tweak_opts, {}), "Defensive boost"))
        else
            fn.vis(ui_state, true)
            local st = fn.get(ui_state, "Shared")
            local idx = CIDX[st] or 1
            local A = aa[idx]
            local enabled = idx == 1 or fn.get(A.enabled)
            fn.vis(A.enabled, true)
            if enabled then
                for key, item in pairs(A) do if key ~= "enabled" then fn.vis(item, true) end end
                local mods = fn.get(A.mods, {})
                local jit, sway, spin, slow = fn.contains(mods, "Jitter"), fn.contains(mods, "Sway"), fn.contains(mods, "Spin"), fn.contains(mods, "Slow Jitter")
                fn.vis(A.jit_min, jit); fn.vis(A.jit_max, jit); fn.vis(A.jit_delaymin, jit); fn.vis(A.jit_delaymax, jit)
                fn.vis(A.sway_amount, sway); fn.vis(A.sway_speed, sway)
                fn.vis(A.spin_amount, spin); fn.vis(A.spin_speed, spin)
                fn.vis(A.slow_amount, slow); fn.vis(A.slow_period, slow)
                fn.vis(A.yaw_static, fn.get(A.yaw) == "Static")
                fn.vis(A.yaw_left, fn.get(A.yaw) == "Switch"); fn.vis(A.yaw_right, fn.get(A.yaw) == "Switch")
                fn.vis(A.yaw_random, fn.get(A.yaw) ~= "Off")
                fn.vis(A.yaw_modifier_value, fn.get(A.yaw_modifier) ~= "Off")
                fn.vis(A.yaw_modifier_random, fn.get(A.yaw_modifier) ~= "Off")
                fn.vis(A.desync_amount, fn.get(A.desync) ~= "Off")
                fn.vis(A.body_jitter, fn.get(A.bodyyaw))
                local def = fn.get(A.defensive)
                fn.vis(A.force_def, def); fn.vis(A.def_pitch, def); fn.vis(A.def_yaw, def)
                local dp = fn.get(A.def_pitch)
                fn.vis(A.def_pitch_value, def and (dp == "Custom" or dp == "3-Way" or dp == "5-Way"))
                fn.vis(A.def_pitch_jit1, def and dp == "Switch"); fn.vis(A.def_pitch_jit2, def and dp == "Switch")
                fn.vis(A.def_pitch_spin, def and dp == "Spin")
                fn.vis(A.def_pitch_random, def and (dp == "Switch" or dp == "3-Way" or dp == "5-Way" or dp == "Vladick" or dp == "Spin"))
                local dy = fn.get(A.def_yaw)
                fn.vis(A.def_yaw_value, def and (dy == "Static" or dy == "3-Way" or dy == "5-Way"))
                fn.vis(A.def_yaw_left, def and dy == "Switch"); fn.vis(A.def_yaw_right, def and dy == "Switch")
                fn.vis(A.def_yaw_spin, def and dy == "Spin")
                fn.vis(A.def_yaw_random, def and (dy == "Switch" or dy == "3-Way" or dy == "5-Way" or dy == "Vladick" or dy == "Spin"))
                fn.vis(A.def_amount, def and (dy == "Jitter" or dy == "Static"))
            end
        end

    elseif tab == "Ragebot" then
        local r = m.rage
        for _, v in pairs(r) do fn.vis(v, true) end
        fn.vis(r.onshot, fn.get(r.resolver)); fn.vis(r.maxdes, fn.get(r.resolver))
        fn.vis(r.pgate, fn.get(r.resolver)); fn.vis(r.pose, fn.get(r.resolver))
        fn.vis(r.hs_dmg, fn.get(r.hs))
        -- the spread guard is a safety floor, independent of adaptive hitscale
        fn.vis(r.spread, true)
        fn.vis(r.spread_strength, fn.get(r.spread))
        fn.vis(r.dt_auto_deadband, fn.get(r.dt_auto))
        fn.vis(r.dthc_off, fn.get(r.dthc)); fn.vis(r.dthc_def, fn.get(r.dthc))
        fn.vis(r.dthc_uncharged, fn.get(r.dthc)); fn.vis(r.dthc_learn, fn.get(r.dthc))
        fn.vis(r.scout_hc, fn.get(r.jump_scout)); fn.vis(r.jump_hc, fn.get(r.jump_scout))
        fn.vis(r.auto_hs_wep, fn.get(r.auto_hs)); fn.vis(r.auto_hs_state, fn.get(r.auto_hs))
        fn.vis(r.ovr_hc_wep, fn.get(r.override_hc))
        fn.vis(r.ovr_scout_hc, fn.get(r.override_hc) and fn.contains(fn.get(r.ovr_hc_wep, {}), "Scout"))
        fn.vis(r.ovr_awp_hc, fn.get(r.override_hc) and fn.contains(fn.get(r.ovr_hc_wep, {}), "AWP"))
        fn.vis(r.ovr_auto_hc, fn.get(r.override_hc) and fn.contains(fn.get(r.ovr_hc_wep, {}), "Auto"))
        fn.vis(r.ovr_r8_hc, fn.get(r.override_hc) and fn.contains(fn.get(r.ovr_hc_wep, {}), "R8"))

    elseif tab == "Utils" then
        local u = m.utils
        for _, v in pairs(u) do fn.vis(v, true) end
        fn.vis(u.log_types, fn.get(u.logs)); fn.vis(u.miss_logs, fn.get(u.logs)); fn.vis(u.miss_dump, fn.get(u.logs) and fn.get(u.miss_logs))
        fn.vis(u.primary, fn.get(u.buybot)); fn.vis(u.pistol, fn.get(u.buybot)); fn.vis(u.nade, fn.get(u.buybot)); fn.vis(u.extra, fn.get(u.buybot))
        fn.vis(u.thirdperson_dist, fn.get(u.thirdperson))
        fn.vis(u.aspect_value, fn.get(u.aspect))
        fn.vis(u.vm_fov, fn.get(u.vm_changer)); fn.vis(u.vm_x, fn.get(u.vm_changer)); fn.vis(u.vm_y, fn.get(u.vm_changer))
        fn.vis(u.vm_z, fn.get(u.vm_changer)); fn.vis(u.vm_opposite, fn.get(u.vm_changer)); fn.vis(u.vm_opposite_knife, fn.get(u.vm_changer))

    elseif tab == "Visuals" then
        local v = m.vis
        for _, item in pairs(v) do fn.vis(item, true) end
        fn.vis(v.ind_color, fn.get(v.indicators)); fn.vis(v.ind_elements, fn.get(v.indicators)); fn.vis(v.ind_gradient, fn.get(v.indicators))
        fn.vis(v.arrows_type, fn.get(v.arrows)); fn.vis(v.arrows_velocity, fn.get(v.arrows))
        fn.vis(v.custom_inds_elements, fn.get(v.custom_inds))
        fn.vis(v.anim_air, fn.get(v.anim_breaker)); fn.vis(v.anim_land, fn.get(v.anim_breaker)); fn.vis(v.anim_additions, fn.get(v.anim_breaker))
        fn.vis(v.watermark_type, fn.get(v.watermark)); fn.vis(v.watermark_pos, fn.get(v.watermark)); fn.vis(v.watermark_color, fn.get(v.watermark))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Config system
-- ═══════════════════════════════════════════════════════════════════════════
function fn.collect_state()
    local out = {}
    local function grab(prefix, item)
        if type(item) ~= "number" then return end
        local ok, a, b, c, d = pcall(ui.get, item)
        if ok then out[prefix] = {a, b, c, d} end
    end
    for gname, group in pairs(m) do
        if gname ~= "cfg" then for k, item in pairs(group) do grab(gname .. "." .. k, item) end end
    end
    for i = 1, #aa do for k, item in pairs(aa[i]) do grab("aa" .. i .. "." .. k, item) end end
    return out
end

function fn.apply_state(state)
    if type(state) ~= "table" then return end
    local map = {}
    for gname, group in pairs(m) do
        if gname ~= "cfg" then for k, item in pairs(group) do map[gname .. "." .. k] = item end end
    end
    for i = 1, #aa do for k, item in pairs(aa[i]) do map["aa" .. i .. "." .. k] = item end end
    for key, vals in pairs(state) do
        local item = map[key]
        if item and type(vals) == "table" then pcall(ui.set, item, unpack(vals)) end
    end
end

function fn.cfg_selected() return (fn.get(m.cfg.list, 0) or 0) + 1 end

function fn.cfg_save_db() if database then database.write(CONFIG_KEY, json.stringify(config_data)) end end

function fn.cfg_create()
    local name = fn.get(m.cfg.name, "")
    if name == "" or fn.contains(config_data.n, name) then return end
    local enc = base64 and base64.encode(json.stringify(fn.collect_state())) or json.stringify(fn.collect_state())
    config_data.n[#config_data.n + 1] = name
    config_data.cfg[#config_data.cfg + 1] = enc
    fn.cfg_save_db()
    fn.set(m.cfg.list, config_data.n)
end

function fn.cfg_load()
    local idx = fn.cfg_selected()
    if idx == 1 then return end
    local raw = config_data.cfg[idx]
    if raw and raw ~= "" then
        local decoded = base64 and base64.decode(raw) or raw
        fn.apply_state(json.parse(decoded))
    end
end

function fn.cfg_save()
    local idx = fn.cfg_selected()
    if idx == 1 then return end
    config_data.cfg[idx] = base64 and base64.encode(json.stringify(fn.collect_state())) or json.stringify(fn.collect_state())
    fn.cfg_save_db()
end

function fn.cfg_delete()
    local idx = fn.cfg_selected()
    if idx == 1 then return end
    t_remove(config_data.n, idx); t_remove(config_data.cfg, idx)
    fn.cfg_save_db()
    fn.set(m.cfg.list, config_data.n)
end

function fn.cfg_export()
    if not clipboard then return end
    local idx = fn.cfg_selected()
    clipboard.set(json.stringify({n = config_data.n[idx] or "cocoyaw", cfg = base64 and base64.encode(json.stringify(fn.collect_state())) or json.stringify(fn.collect_state())}))
end

function fn.cfg_import()
    if not clipboard then return end
    local parsed = json.parse(clipboard.get())
    if not parsed or not parsed.n then return end
    config_data.n[#config_data.n + 1] = parsed.n
    config_data.cfg[#config_data.cfg + 1] = parsed.cfg or ""
    fn.cfg_save_db()
    fn.set(m.cfg.list, config_data.n)
end

m.cfg_buttons = {
    fn.bt("CY Create", fn.cfg_create), fn.bt("CY Load", fn.cfg_load), fn.bt("CY Save", fn.cfg_save),
    fn.bt("CY Delete", fn.cfg_delete), fn.bt("CY Export", fn.cfg_export), fn.bt("CY Import", fn.cfg_import),
}

-- the config buttons are created after the first snapshot, so rebuild ITEMS to
-- include them; otherwise they are never hidden and leak onto every tab
ITEMS = fn.all_items()

for _, item in ipairs(ITEMS) do pcall(ui.set_callback, item, fn.refresh_menu) end
for _, item in ipairs({ui_tab, ui_sub, ui_state}) do pcall(ui.set_callback, item, fn.refresh_menu) end
fn.refresh_menu()

-- ═══════════════════════════════════════════════════════════════════════════
--  Resolver configuration + state
-- ═══════════════════════════════════════════════════════════════════════════
local CY = {
    LEARN_SPEED = 0.55, CONF_DECAY = 0.12, LBY_WINDOW = 4, LBY_BASE = 1.1, LBY_MARGIN = 0.12,
    FLICK = 90, MIN_SHOTS = 2, DEF_DESYNC = 12, DEF_STREAK = 4, DEF_AVG = 15, DEF_L6 = 0.1,
    SAMPLES = 24, CHOKE_DEF = 2, SWAY_THRESH = 3, HIST = 4, JIT_BIG = 30, JIT_RETURN = 15,
    JIT_CONF_GATE = 0.6, FL_MAG_FLOOR = 42, FL_MAG_HIGH = 55,
    ONSHOT_WINDOW = 0.2, ONSHOT_TRUST = 0.45, ONSHOT_COMMIT = 0.125,
    MISS_FLIP = 24, EXTRAP_TICKS = 3, ACCEL_W = 0.6, PITCH_GATE = 45, POSE_MIN = 2,
    STATE = {INVALID = 0, STANDING = 1, MOVING = 2, AIR = 3, CROUCHING = 4, CROUCH_MOVING = 5, AIR_CROUCH = 6, RUSHING = 7},
    SNAME = {[0] = "INVALID", [1] = "STAND", [2] = "MOVE", [3] = "AIR", [4] = "CROUCH", [5] = "CR-MOVE", [6] = "AIR-CR", [7] = "RUSH"},
    DEF_OFFSETS = {[1] = 30, [2] = 20, [3] = 0, [4] = -10, [5] = 15, [6] = 0, [7] = 25},
    FL_GROUND = b_lshift(1, 0), FL_DUCK = b_lshift(1, 1),
    ESP_TELEPORT = b_lshift(1, 17), ESP_HITTABLE = b_lshift(1, 11),
    SPEED_RUSH = 100, RUSH_DIST = 600, LAYERS = {3, 6, 12}, STAGES = 7,
}
local ST = CY.STATE
local BT_CAP = 62
local ents = {}

function fn.clear_ents() for k in pairs(ents) do ents[k] = nil end end
function fn.clear_ent(i) ents[i] = nil end

function fn.physics(idx)
    local e = ents[idx]
    if not e then e = {}; ents[idx] = e end
    if e.p then return e.p end
    local off, wt, sc, ly = {}, {}, {}, {}
    for s in pairs(CY.DEF_OFFSETS) do off[s] = CY.DEF_OFFSETS[s]; wt[s] = 1; sc[s] = 0 end
    for i = 1, 3 do ly[CY.LAYERS[i]] = {sq = 0, pc = 0, w = 0, r = 0, c = 0, ok = false} end
    e.p = {
        st = 0, pst = 0, px = 0, py = 0, pz = 0, vx = 0, vy = 0, vz = 0, pvx = 0, pvy = 0, pvz = 0,
        ax = 0, ay = 0, az = 0, pax = 0, pay = 0, paz = 0, jx = 0, jy = 0, jz = 0,
        prx = 0, pry = 0, prz = 0, ap = 0, aw = 0, pyw = 0, lby = 0, plby = 0,
        ds = 0, dss = 0, lt = 0, ly = ly, off = off, wt = wt, sscore = sc,
        lbu = false, lbt = 0, lbs = {}, lbn = 0, lba = 0, lbv = 0, fl = false, yv = 0, sr = 0, sd = 0, srt = 0,
        dm = false, dmt = 0, db = {d = {}, w = 0, n = 0, s = 0}, dh = {}, ad = 0, ls = 0, def = false, dft = 0,
        psm = 0, simt = 0, psimt = 0, chk = 1, sok = false, my = 0, ml = false, dv = 0, pds = 0,
        sf = 0, swt = 0, smn = -60, smx = 60, swd = false, swh = 0, fss = 0, fst = 0, msd = 0, msu = 0,
        gf = 0, hasanim = false, pose = 0, pose_ok = false, pbody = 0, pbody_ok = false,
        maxdes = 58, maxdes_ok = false, maxdes_t = 0, hist = {}, histn = 0, jit = "unknown", jitc = 0,
        maxobs = 0, maxobs_t = 0, shot_t = 0, onshot = false, oyaw = 0, ocap = 0, ovalid = false,
        meas_miss = 0, tele = false, hittable = false, lkg = 0, lkg_t = 0, lkg_ok = false, aa = false, src = "none",
    }
    return e.p
end

function fn.history(idx)
    local e = ents[idx]
    if not e then e = {}; ents[idx] = e end
    if e.h then return e.h end
    local h = {ht = 0, ms = 0, ns = 0, cf = 0, cft = 0, hb = {}, mb = {}, g = {}, bd = {}, sh = {}, sm = {}}
    for _, s in pairs(ST) do if type(s) == "number" then h.hb[s] = 0; h.mb[s] = 0 end end
    for i = 1, CY.STAGES do h.sh[i] = 0; h.sm[i] = 0 end
    e.h = h
    return h
end

function fn.progress(idx)
    local e = ents[idx]
    if not e then e = {}; ents[idx] = e end
    if e.pr then return e.pr end
    local n = g_realtime()
    e.pr = {s = 1, p = 0, t0 = n, l = n, r = false}
    return e.pr
end

function fn.brute(idx)
    local e = ents[idx]
    if not e then e = {}; ents[idx] = e end
    if e.b then return e.b end
    e.b = {i = 1, mr = 0, cy = 0}
    return e.b
end

function fn.ring_push(ring, val, cap)
    ring.w = ring.w % cap + 1
    if ring.n >= cap then ring.s = ring.s - (ring.d[ring.w] or 0) else ring.n = ring.n + 1 end
    ring.d[ring.w] = val
    ring.s = ring.s + val
end

function fn.classify(pd)
    local h, n = pd.dh, #pd.dh
    if n < 2 then pd.jit = "unknown"; pd.jitc = 0; return end
    if n < CY.HIST then
        if m_abs(h[1] - h[2]) < 3 then pd.jit = "static"; pd.jitc = 0.4 end
        return
    end
    local y0, y1, y2, y3 = h[1], h[2], h[3], h[4]
    local d01, d02, d12, d13, d23 = y0 - y1, y0 - y2, y1 - y2, y1 - y3, y2 - y3
    local step = m_abs(d01)
    if step < 3 and m_abs(d12) < 3 and m_abs(d23) < 3 then
        pd.jit = "static"; pd.jitc = 1.0
    elseif step > CY.JIT_BIG and m_abs(d02) < CY.JIT_RETURN and m_abs(d13) < CY.JIT_RETURN then
        pd.jit = "jitter2"; pd.jitc = fn.clamp(1 - (m_abs(d02) / CY.JIT_RETURN) * 0.5, 0.5, 1.0)
    elseif step > CY.JIT_RETURN or m_abs(d12) > CY.JIT_RETURN or m_abs(d23) > CY.JIT_RETURN then
        pd.jit = "skitter"; pd.jitc = fn.clamp(step / 60, 0.3, 1.0)
    else
        pd.jit = "unknown"; pd.jitc = 0
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Global local-player state
-- ═══════════════════════════════════════════════════════════════════════════
local mg = {
    lp = {id = -1, origin = vector(), speedxy = 0, speedz = 0, duck = false, tickbase = 0},
    state = "Standing", realstate = "Standing", laststate = "Standing", stateswitch = false,
    weaponid = 0, weaponname = "", weaponswitch = false,
    exploit = "", declaredloc = vector(), currentloc = vector(), declaredyaw = 0, fakeyaw = 0,
    shottimer = 0, shotbool = false, jumpscout = false, autopeekfix = 0, airtime = 0, groundtimer = 0,
    threat = -1, fsside = nil, fsyaw = nil, atyaw = nil, hittable_any = false,
    indefensive = false, ext_fired = false, lc_broken = false, head_peek = 0,
    tb = {cmd = nil, max = nil, diff = nil, depth = 0}, own_desync = 0, own_max = 58, fl_phase = 0,
    fs = {
        left = {t1 = {startpos = vector(), endpos = vector(), fraction = 1, hit = -1}, t2 = {startpos = vector(), endpos = vector(), fraction = 1, hit = -1}},
        right = {t1 = {startpos = vector(), endpos = vector(), fraction = 1, hit = -1}, t2 = {startpos = vector(), endpos = vector(), fraction = 1, hit = -1}},
        startpos = vector(),
    },
}
local round_ended = false

-- ═══════════════════════════════════════════════════════════════════════════
--  Resolver: acquire
-- ═══════════════════════════════════════════════════════════════════════════
function fn.acquire(ent)
    local pd = fn.physics(ent)
    local now = g_curtime()
    if e_dormant(ent) then
        if not pd.dm then pd.dm = true; pd.dmt = now end
        return pd
    end
    if pd.dm then
        pd.dm = false
        pd.pvx, pd.pvy, pd.pvz = 0, 0, 0; pd.ax, pd.ay, pd.az = 0, 0, 0
        pd.jx, pd.jy, pd.jz = 0, 0, 0; pd.sr, pd.ad, pd.ls, pd.dft = 0, 0, 0, 0
        pd.def = false; pd.db = {d = {}, w = 0, n = 0, s = 0}
        pd.dh = {}; pd.hist = {}; pd.histn = 0; pd.psm = 0; pd.sok = false
        pd.lbs = {}; pd.lbn = 0; pd.jit = "unknown"; pd.jitc = 0; pd.ovalid = false
    end

    local esp = entity.get_esp_data and entity.get_esp_data(ent) or nil
    local ef = (esp and esp.flags) or 0
    pd.tele = b_band(ef, CY.ESP_TELEPORT) ~= 0
    pd.hittable = b_band(ef, CY.ESP_HITTABLE) ~= 0

    local sim = e_prop(ent, "m_flSimulationTime") or now
    local simt = fn.ticks(sim) - (pd.tele and 14 or 0)
    if pd.simt ~= 0 and simt - pd.simt < 1 then return pd end
    pd.psimt, pd.simt = pd.simt, simt
    if pd.psm > 0 and pd.sok then
        local sd = sim - pd.psm
        if sd > 0 then pd.chk = fn.clamp(m_floor(sd * TICK_INV + 0.5), 1, 16) end
    end
    pd.sok = pd.psm > 0; pd.psm = sim

    local ox, oy, oz = e_origin(ent)
    pd.px, pd.py, pd.pz = ox or 0, oy or 0, oz or 0
    local vx, vy, vz = e_prop(ent, "m_vecVelocity[0]") or 0, e_prop(ent, "m_vecVelocity[1]") or 0, e_prop(ent, "m_vecVelocity[2]") or 0
    pd.pvx, pd.pvy, pd.pvz = pd.vx, pd.vy, pd.vz
    pd.vx, pd.vy, pd.vz = vx, vy, vz
    local dt = now - pd.lt
    if dt > 0 and dt < 1 then
        local idt = 1 / dt
        local nax, nay, naz = (vx - pd.pvx) * idt, (vy - pd.pvy) * idt, (vz - pd.pvz) * idt
        if pd.pax ~= 0 or pd.pay ~= 0 then pd.jx = (nax - pd.pax) * idt; pd.jy = (nay - pd.pay) * idt; pd.jz = (naz - pd.paz) * idt end
        pd.pax, pd.pay, pd.paz = pd.ax, pd.ay, pd.az
        pd.ax, pd.ay, pd.az = nax, nay, naz
    end
    local et = TICK_IV * CY.EXTRAP_TICKS
    local et2 = et * et
    local aw_, jw_ = et2 * CY.ACCEL_W, et2 * et * 0.15
    pd.prx = pd.px + vx * et + pd.ax * aw_ + pd.jx * jw_
    pd.pry = pd.py + vy * et + pd.ay * aw_ + pd.jy * jw_
    pd.prz = pd.pz + vz * et + pd.az * aw_

    local spd2 = m_sqrt(vx * vx + vy * vy)
    if pd.sd ~= 0 and spd2 > 10 then
        local nd = m_atan2(vy, vx)
        if m_abs(fn.norm(m_deg(nd - pd.sd))) > 90 then pd.sr = pd.sr + 1; pd.srt = now end
        pd.sd = nd
    elseif spd2 > 10 then pd.sd = m_atan2(vy, vx) else pd.sd = 0 end
    if now - pd.srt > 1 then pd.sr = m_max(0, pd.sr - 1) end

    local ap, aw = e_prop(ent, "m_angEyeAngles")
    pd.pyw, pd.ap, pd.aw = pd.aw, ap or 0, aw or 0
    pd.plby, pd.lby = pd.lby, e_prop(ent, "m_flLowerBodyYawTarget") or 0
    t_insert(pd.hist, 1, pd.aw); if #pd.hist > CY.HIST then t_remove(pd.hist) end; pd.histn = #pd.hist

    local wep = e_weapon(ent)
    local shot = wep and e_prop(wep, "m_fLastShotTime") or nil
    pd.onshot = false
    if type(shot) == "number" and shot > 0 then
        local since = now - shot
        if since >= 0 and since <= CY.ONSHOT_WINDOW then
            pd.onshot = true
            if shot ~= pd.shot_t then pd.oyaw = pd.aw; pd.ocap = now; pd.ovalid = true end
        end
        pd.shot_t = shot
    end
    if pd.ovalid and now - pd.ocap > CY.ONSHOT_TRUST then pd.ovalid = false end

    local ast = fn.animbase(ent)
    pd.hasanim, pd.maxdes_ok = false, false
    if ast then
        pcall(function()
            local gf, ey = fn.ASF(ast, AS.GOAL_FEET), fn.ASF(ast, AS.EYE_YAW)
            if fn.valid_angle(gf) then
                local anchor = fn.valid_angle(ey) and ey or pd.aw
                local d = fn.delta(anchor, gf)
                if m_abs(d) <= 62 then pd.gf = gf; pd.hasanim = true; if fn.valid_angle(ey) then pd.aw = ey end; pd.ds = d end
            end
        end)
        local md = fn.max_desync(ast)
        if md then pd.maxdes = md; pd.maxdes_ok = true; pd.maxdes_t = now end
    end
    if not pd.maxdes_ok and pd.maxdes_t > 0 and now - pd.maxdes_t < 1.5 then pd.maxdes_ok = true end

    local pv = fn.pose_body(ent)
    if pv ~= nil then
        pd.pose, pd.pose_ok = pv, true
        if m_abs(pv) > CY.POSE_MIN then pd.pbody = fn.norm(pd.aw - pv); pd.pbody_ok = true else pd.pbody = pd.aw; pd.pbody_ok = false end
    else
        pd.pose_ok, pd.pbody_ok = false, false
    end
    if not pd.hasanim then pd.ds = pd.pbody_ok and pd.pose or fn.delta(pd.aw, pd.lby) end
    pd.dss = pd.ds > 0 and 1 or -1
    t_insert(pd.dh, 1, pd.ds); if #pd.dh > CY.HIST then t_remove(pd.dh) end
    fn.classify(pd)

    if (pd.hasanim or pd.pbody_ok) and pd.chk <= 3 then
        local a = m_abs(pd.ds)
        if a > pd.maxobs then pd.maxobs = a; pd.maxobs_t = now end
    end
    if now - pd.maxobs_t > 5 then pd.maxobs = pd.maxobs * 0.95 end

    pd.dv = (pd.ds - pd.pds) / m_max(dt, 0.001)
    local psign, csign = pd.pds > 0 and 1 or -1, pd.ds > 0 and 1 or -1
    pd.pds = pd.ds
    if csign ~= psign and m_abs(pd.ds) > 5 then
        if pd.swt > 0 then
            local half = now - pd.swt
            if half > 0.02 and half < 2 then pd.swh = pd.swh > 0 and fn.lerp(pd.swh, half, 0.4) or half end
        end
        pd.sf = pd.sf + 1; pd.swt = now
    end
    if now - pd.swt > 2 then pd.sf = m_max(0, pd.sf - 1) end
    pd.swd = pd.sf >= CY.SWAY_THRESH
    if pd.swd then
        pd.smx = fn.lerp(pd.smx, m_max(pd.ds, pd.smx), 0.3) * 0.995
        pd.smn = fn.lerp(pd.smn, m_min(pd.ds, pd.smn), 0.3) * 0.995
    else
        local a = m_abs(pd.ds); pd.smx, pd.smn = a, -a
    end

    local ld = m_abs(fn.delta(pd.lby, pd.plby))
    pd.lbu = false
    if ld > 2 and spd2 < 5 then
        pd.lbu = true; pd.lbt = g_tick(); pd.lbv = pd.lby
        pd.lbs[#pd.lbs + 1] = now; if #pd.lbs > 8 then t_remove(pd.lbs, 1) end
        if #pd.lbs >= 2 then
            local s, cnt = 0, 0
            for i = 2, #pd.lbs do s = s + pd.lbs[i] - pd.lbs[i - 1]; cnt = cnt + 1 end
            pd.lba = s / cnt; pd.lbn = now + pd.lba
        else pd.lbn = now + CY.LBY_BASE end
    end

    pd.ml = spd2 > 15
    if pd.ml then pd.my = m_deg(m_atan2(vy, vx)) end
    pd.yv = m_abs(fn.delta(pd.aw, pd.pyw)) / m_max(dt, 0.001)
    pd.fl = pd.yv > (CY.FLICK * TICK_INV)
    fn.ring_push(pd.db, m_abs(pd.ds), CY.SAMPLES)
    pd.ad = pd.db.n > 0 and pd.db.s / pd.db.n or 0
    pd.ls = m_abs(pd.ds) < CY.DEF_DESYNC and (pd.ls + 1) or 0

    for i = 1, 3 do
        local li, l = CY.LAYERS[i], fn.layerbase(ent, CY.LAYERS[i])
        local t = pd.ly[li]
        if l then
            t.ok = pcall(function() t.sq = fn.ALI(l, AL.SEQUENCE); t.pc = fn.ALF(l, AL.PREV_CYCLE); t.w = fn.ALF(l, AL.WEIGHT); t.r = fn.ALF(l, AL.PLAYBACK); t.c = fn.ALF(l, AL.CYCLE) end)
        else t.ok = false end
    end

    local flags = e_prop(ent, "m_fFlags") or 0
    local ground, duck, moving = b_band(flags, CY.FL_GROUND) ~= 0, b_band(flags, CY.FL_DUCK) ~= 0, spd2 > 5
    pd.pst = pd.st
    if not ground then pd.st = duck and ST.AIR_CROUCH or ST.AIR
    elseif duck then pd.st = moving and ST.CROUCH_MOVING or ST.CROUCHING
    elseif moving then pd.st = ST.MOVING
    else pd.st = ST.STANDING end
    if spd2 > CY.SPEED_RUSH then
        local mo = mg.lp.origin
        local dx, dy, dz = (mo.x or 0) - pd.px, (mo.y or 0) - pd.py, (mo.z or 0) - pd.pz
        local dist = m_sqrt(dx * dx + dy * dy + dz * dz)
        local s3 = m_sqrt(vx * vx + vy * vy + vz * vz) + 1e-6
        if dist < CY.RUSH_DIST and dist > 0 and (vx / s3) * (dx / dist) + (vy / s3) * (dy / dist) + (vz / s3) * (dz / dist) > 0.6 then pd.st = ST.RUSHING end
    end

    pd.aa = m_abs(pd.ap) > CY.PITCH_GATE or m_abs(pd.ds) > 8 or pd.maxobs > 12
        or pd.jit == "jitter2" or pd.jit == "skitter" or pd.chk >= 4 or pd.ovalid or (pd.pose_ok and m_abs(pd.pose) > 8)
    local l6 = pd.ly[6]
    local can_def = pd.st == ST.STANDING or pd.st == ST.CROUCHING
    local collapsed = m_abs(pd.ds) < CY.DEF_DESYNC
    pd.def = pd.sok and pd.chk <= CY.CHOKE_DEF and can_def and
        (pd.ad < CY.DEF_AVG or pd.ls >= CY.DEF_STREAK or (l6.ok and l6.w < CY.DEF_L6 and collapsed) or (spd2 < 5 and m_abs(pd.ds) < 8))
    pd.dft = pd.def and pd.dft + 1 or m_max(0, pd.dft - 2)
    pd.lt = now
    return pd
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Enemy freestanding
-- ═══════════════════════════════════════════════════════════════════════════
function fn.freestand_enemy(ent, pd, me)
    local ex, ey, ez = c_eye()
    if not ex then return 0 end
    local perp = m_atan2(pd.py - ey, pd.px - ex) + 1.5707963
    local cp, sp = m_cos(perp), m_sin(perp)
    local hz = pd.pz + 64
    for _, r in ipairs({16, 32}) do
        local ox, oy = cp * r, sp * r
        local lh = c_trace_b(me, ex, ey, ez, pd.px + ox, pd.py + oy, hz)
        local rh = c_trace_b(me, ex, ey, ez, pd.px - ox, pd.py - oy, hz)
        if lh == ent and rh ~= ent then return 1 elseif rh == ent and lh ~= ent then return -1 end
    end
    return 0
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Resolver: estimate (magnitude, side, override, source)
-- ═══════════════════════════════════════════════════════════════════════════
function fn.estimate(ent, st)
    local e = ents[ent]; if not e or not e.p then return 0, 1, nil, "none" end
    local pd, tick, now, eye = e.p, g_tick(), g_curtime(), e.p.aw

    if pd.lbu and tick - pd.lbt < CY.LBY_WINDOW then return 0, 1, pd.lby, "lby" end

    local body, src
    if pd.hasanim then body, src = pd.gf, "anim"
    elseif fn.get(m.rage.pose, true) and pd.pbody_ok then body, src = pd.pbody, "pose" end

    if not body and fn.get(m.rage.onshot, true) and pd.ovalid and now - pd.ocap < CY.ONSHOT_COMMIT then
        return 0, 1, pd.oyaw, "onshot"
    end

    if body then
        local mag, d = m_abs(fn.delta(eye, body)), fn.delta(body, eye)
        local side = m_abs(d) <= 3 and pd.dss or (d > 0 and 1 or -1)
        local sc = pd.sscore[st]
        if sc and m_abs(sc) >= 4 then side = sc > 0 and 1 or -1 end
        if pd.msd ~= 0 and tick < pd.msu and (pd.meas_miss or 0) >= 2 then side = pd.msd end
        if fn.get(m.rage.maxdes, true) and pd.maxdes_ok then mag = m_min(mag, pd.maxdes) end
        return fn.clamp(mag, 0, 58), side, nil, src
    end

    -- inference chain
    local step = pd.histn >= 2 and m_abs(fn.delta(pd.hist[1], pd.hist[2])) or 0
    local mag
    if pd.maxobs > 10 and now - pd.maxobs_t < 8 then mag = pd.maxobs
    elseif step > 8 then mag = fn.clamp(step * 0.9, 12, 58)
    elseif pd.chk >= 10 then mag = CY.FL_MAG_HIGH
    elseif pd.chk >= 6 then mag = CY.FL_MAG_FLOOR
    else mag = m_max(pd.ad, 5) end
    if pd.lkg_ok and now - pd.lkg_t < 3 then mag = fn.lerp(mag, m_abs(fn.delta(eye, pd.lkg)), 0.3) end
    if fn.get(m.rage.maxdes, true) and pd.maxdes_ok then mag = m_min(mag, pd.maxdes) end
    mag = fn.clamp(mag, 0, 58)

    local side = m_abs(pd.ds) > 3 and pd.dss or 0
    if side == 0 and pd.jit == "jitter2" and pd.jitc > 0.5 and #pd.dh >= 2 then
        local d = pd.dh[1] - pd.dh[2]
        if m_abs(d) > 5 then side = d > 0 and -1 or 1 end
    end
    local sc = pd.sscore[st]
    if sc and m_abs(sc) >= 2 and (side == 0 or m_abs(sc) >= 4) then side = sc > 0 and 1 or -1 end
    if pd.ml and mag > 3 and (st == ST.MOVING or st == ST.CROUCH_MOVING or st == ST.RUSHING) then
        local mv = fn.norm(pd.my - eye)
        if m_abs(mv) > 10 and side == 0 then side = mv > 0 and 1 or -1 end
    end
    if pd.swd and pd.swh > 0 then
        local from = pd.dv >= 0 and pd.smn or pd.smx
        local to = pd.dv >= 0 and pd.smx or pd.smn
        local ph = fn.clamp((now - pd.swt + TICK_IV * 2) / pd.swh, 0, 1)
        local eased = from + (to - from) * (0.5 - 0.5 * m_cos(ph * m_pi))
        if m_abs(eased) > 3 then
            side = eased > 0 and 1 or -1
            mag = fn.clamp(m_abs(eased), mag * 0.5, 58)
            if fn.get(m.rage.maxdes, true) and pd.maxdes_ok then mag = m_min(mag, pd.maxdes) end
        end
    end
    if pd.fss ~= 0 and tick - pd.fst < 20 then side = pd.fss end
    if pd.msd ~= 0 and tick < pd.msu then side = pd.msd end
    if pd.jit == "skitter" and pd.jitc > CY.JIT_CONF_GATE then mag = mag * 0.55 end
    if side == 0 then side = 1 end
    return mag, side, nil, "infer"
end

function fn.release_resolver(ent)
    p_set(ent, "Correction Active", true)
    p_set(ent, "Force Body Yaw", false)
    p_set(ent, "Force Pitch", false)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Resolver: resolve
-- ═══════════════════════════════════════════════════════════════════════════
function fn.resolve(ent)
    local pd = fn.acquire(ent)
    if pd.st == ST.INVALID or pd.dm then return end
    local e = ents[ent]; if not e then return end
    local pr, h = fn.progress(ent), fn.history(ent)
    local now, ct = g_realtime(), g_curtime()
    local dt = now - pr.l
    if now - h.cft > 2 then h.cf = m_max(0, h.cf - CY.CONF_DECAY * (now - h.cft)); h.cft = now end
    local xp = pd.ap < -89 or pd.ap > 89

    local has_reading = pd.hasanim or (fn.get(m.rage.pose, true) and pd.pbody_ok)
    if not has_reading and fn.get(m.rage.onshot, true) and pd.ovalid and ct - pd.ocap < CY.ONSHOT_COMMIT then
        p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", true); p_set(ent, "Force Body Yaw Value", pd.oyaw)
        p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
        pr.s, pr.r = 4, true
        e.v = {y = pd.oyaw, o = 0, bo = 0, bi = 0, s = pd.dss, st = pd.st, d = false, ad = pd.ad, mag = 0, onshot = true, src = "onshot"}
        pr.l = now; return
    end

    if fn.get(m.rage.pgate, true) and not pd.aa then
        fn.release_resolver(ent)
        e.v = {y = pd.aw, o = 0, bo = 0, bi = 0, s = 0, st = pd.st, ad = pd.ad, mag = 0, skipped = true, src = "skip"}
        pr.l = now; return
    end

    if ent == mg.threat and pd.st ~= ST.AIR and pd.st ~= ST.AIR_CROUCH then
        local me = e_local()
        if me then local f = fn.freestand_enemy(ent, pd, me); if f ~= 0 then pd.fss = f; pd.fst = g_tick() end end
    end

    local ss = (pd.st == ST.STANDING and 2) or (pd.st == ST.AIR and 1.5) or (pd.st == ST.RUSHING and 0.8) or 1
    local total = h.ht + h.ms
    local c = total > 0 and (0.8 + h.ht / total) or 1
    pr.p = m_min(100, pr.p + 24 * dt * ss * c)
    if pr.p < 25 then pr.s = 1
    elseif pr.p < 50 then pr.s = 2
    elseif pr.p < 75 then pr.s = total >= CY.MIN_SHOTS and 3 or 2
    else pr.s = (total >= CY.MIN_SHOTS and h.ht > 0) and 4 or 3; pr.r = pr.s == 4 end

    if pd.def and pd.dft >= 3 then
        local dy = pd.hasanim and pd.gf or (pd.pbody_ok and pd.pbody or pd.lby)
        p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", true); p_set(ent, "Force Body Yaw Value", dy)
        p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
        pr.s, pr.r = 4, true
        e.v = {y = dy, o = 0, bo = 0, bi = 0, s = pd.dss, st = pd.st, d = true, ad = pd.ad, mag = 0, src = "defensive"}
        pr.l = now; return
    end

    if pd.lbn > 0 and pd.st == ST.STANDING and not pd.ml then
        local tts = pd.lbn - ct
        if tts > -CY.LBY_MARGIN and tts < CY.LBY_MARGIN then
            local ly = pd.lbv ~= 0 and pd.lbv or pd.lby
            p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", true); p_set(ent, "Force Body Yaw Value", ly)
            p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
            e.v = {y = ly, o = 0, bo = 0, bi = 0, s = pd.dss, st = pd.st, ad = pd.ad, mag = 0, lbypred = true, src = "lbytimer"}
            pr.l = now; return
        end
    end

    local mag, side, override, src = fn.estimate(ent, pd.st)
    local bs = fn.brute(ent)
    pd.src = src

    if (src == "anim" or src == "pose") and (pd.meas_miss or 0) < 3 then
        local fy = fn.norm(pd.aw + side * mag)
        p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", mag >= 1)
        if mag >= 1 then p_set(ent, "Force Body Yaw Value", fy) end
        p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
        e.v = {y = fy, o = side * mag, bo = mag, bi = 0, s = side, st = pd.st, d = false, ad = pd.ad,
               sw = pd.swd, mag = mag, jit = pd.jit, chk = pd.chk, anim = pd.hasanim, maxds = pd.maxdes, maxok = pd.maxdes_ok, tele = pd.tele, src = src}
        pr.l = now; return
    end

    local mode = bs.i
    if (h.sm[mode] or 0) >= 2 and (h.sh[mode] or 0) == 0 then
        local bi, br = mode, -1
        for i = 1, CY.STAGES do
            local sh, sm = h.sh[i] or 0, h.sm[i] or 0
            if sm < 2 or sh > 0 then local r = (sh + 1) / (sm + 1); if r > br then br = r; bi = i end end
        end
        mode = bi
    end

    local ceiling = (fn.get(m.rage.maxdes, true) and pd.maxdes_ok) and pd.maxdes or 58
    local ext = m_min(m_max(mag, 52 + (bs.cy >= 2 and 6 or 0)), ceiling)
    local us, um = side, mag
    if mode == 1 then us, um = side, mag
    elseif mode == 2 then us, um = -side, mag
    elseif mode == 3 then us, um = side, ext
    elseif mode == 4 then us, um = -side, ext
    elseif mode == 5 then if pd.lbv ~= 0 then override = pd.lbv else us, um = side, mag * 0.5 end
    elseif mode == 6 then us, um = side, 0
    elseif mode == 7 then if pd.lkg_ok and now - pd.lkg_t < 10 then override = pd.lkg else us, um = -side, ext end end
    um = fn.clamp(um, 0, ceiling)
    local fy = override or fn.norm(pd.aw + us * um)

    p_set(ent, "Correction Active", true)
    p_set(ent, "Force Body Yaw", um ~= 0 or override ~= nil)
    if um ~= 0 or override ~= nil then p_set(ent, "Force Body Yaw Value", fy) end
    p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
    e.v = {y = fy, o = us * um, bo = mag, bi = mode, s = us, st = pd.st, d = false, ad = pd.ad,
           sw = pd.swd, mag = um, jit = pd.jit, chk = pd.chk, anim = pd.hasanim, maxds = pd.maxdes, maxok = pd.maxdes_ok, tele = pd.tele, src = src}
    bs.i, pr.l = mode, now
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Resolver: learn
-- ═══════════════════════════════════════════════════════════════════════════
local RESOLVER_MISS = {["?"] = true, resolver = true}
function fn.learn(ent, hit, hs, reason)
    local e = ents[ent]; if not e or not e.p or not e.v or e.v.skipped then return end
    local pd, h, rv = e.p, fn.history(ent), e.v
    local tick = g_tick()
    if e.lt == tick then return end
    e.lt = tick
    local st, off, bidx = pd.st, rv.o or 0, rv.bi or 0
    local blame = hit or reason == nil or RESOLVER_MISS[reason] or false
    h.ns = h.ns + 1
    local kh, km = 0.25 + 0.35 * CY.LEARN_SPEED, 0.15 + 0.25 * CY.LEARN_SPEED
    local vs = rv.s or 0
    if vs ~= 0 and blame then pd.sscore[st] = fn.clamp((pd.sscore[st] or 0) + (hit and vs * 2 or -vs), -8, 8) end
    if hit then
        h.ht = h.ht + 1; h.hb[st] = (h.hb[st] or 0) + 1
        h.g[#h.g + 1] = {yaw = rv.y, off = off, st = st, t = g_realtime(), hs = hs, stg = bidx}
        h.cf = m_min(100, h.cf + (hs and 12 or 6))
        pd.wt[st] = (pd.wt[st] or 1) + (hs and 2 or 1)
        pd.off[st] = (pd.off[st] or 0) * (1 - kh) + off * kh
        if bidx >= 1 and bidx <= CY.STAGES then h.sh[bidx] = (h.sh[bidx] or 0) + 1 end
        local bs = fn.brute(ent); bs.i = bidx > 0 and bidx or 1; bs.mr = 0
        pd.msd, pd.meas_miss = 0, 0
        pd.lkg, pd.lkg_t, pd.lkg_ok = rv.y, g_realtime(), true
    else
        h.ms = h.ms + 1; h.mb[st] = (h.mb[st] or 0) + 1
        h.bd[#h.bd + 1] = {yaw = rv.y, off = off, st = st, t = g_realtime(), stg = bidx}
        if not blame then while #h.bd > 48 do t_remove(h.bd, 1) end; return end
        h.cf = m_max(0, h.cf - (6 + m_min(h.ms, 10)))
        pd.off[st] = (pd.off[st] or 0) * (1 - km) + (-off * 0.6) * km
        if bidx >= 1 and bidx <= CY.STAGES then h.sm[bidx] = (h.sm[bidx] or 0) + 1 end
        local bs = fn.brute(ent); bs.mr = bs.mr + 1; if bs.i >= CY.STAGES then bs.cy = bs.cy + 1 end; bs.i = (bs.i % CY.STAGES) + 1
        pd.msd = (rv.s or 1) > 0 and -1 or 1; pd.msu = tick + CY.MISS_FLIP
        pd.meas_miss = (rv.src == "anim" or rv.src == "pose") and ((pd.meas_miss or 0) + 1) or 0
        local p = fn.progress(ent); if p.p < 70 then p.p = 70 end
        if pd.lkg_ok and m_abs(fn.delta(pd.lkg, rv.y)) < 10 then pd.lkg_ok = false end
        if rv.onshot then pd.ovalid = false end
    end
    while #h.g > 48 do t_remove(h.g, 1) end
    while #h.bd > 48 do t_remove(h.bd, 1) end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Backtrack (auto-sniper LBY correction)
-- ═══════════════════════════════════════════════════════════════════════════
function fn.is_autosniper(n) return n == "CWeaponSCAR20" or n == "CWeaponG3SG1" end

function fn.backtrack_record(en)
    for i = 1, #en do
        local e2 = en[i]
        if not e_dormant(e2) then
            local e = ents[e2]; if not e then e = {}; ents[e2] = e end
            if not e.bt then e.bt = {d = {}, w = 0, n = 0} end
            local r = e.bt
            local hx, hy, hz = e_hitbox(e2, 0)
            local ox, oy, oz = e_origin(e2)
            if hx and ox then
                r.w = r.w % BT_CAP + 1
                local s = r.d[r.w]
                if not s then s = {sim = 0, head = {0, 0, 0}, org = {0, 0, 0}, vel = {0, 0, 0}, tick = 0}; r.d[r.w] = s end
                s.sim = e_prop(e2, "m_flSimulationTime") or g_curtime()
                s.head[1], s.head[2], s.head[3] = hx, hy, hz
                s.org[1], s.org[2], s.org[3] = ox, oy, oz
                s.vel[1] = e_prop(e2, "m_vecVelocity[0]") or 0
                s.vel[2] = e_prop(e2, "m_vecVelocity[1]") or 0
                s.vel[3] = e_prop(e2, "m_vecVelocity[2]") or 0
                s.tick = g_tick()
                if r.n < BT_CAP then r.n = r.n + 1 end
            end
        end
    end
end

function fn.backtrack_best(ent)
    local e = ents[ent]; if not e or not e.bt then return nil end
    local r = e.bt; if r.n == 0 then return nil end
    local me = e_local(); local ex, ey, ez = c_eye()
    if not me or not ex then return nil end
    local best, bs = nil, -1e9
    for i = 0, r.n - 1 do
        local rec = r.d[((r.w - 1 - i) % BT_CAP) + 1]
        if rec then
            local v1, v2 = rec.vel[1], rec.vel[2]
            local spd = m_sqrt(v1 * v1 + v2 * v2)
            local h = c_trace_b(me, ex, ey, ez, rec.head[1], rec.head[2], rec.head[3])
            local sc = (200 - fn.clamp(spd, 0, 200)) + (h == ent and 50 or -25) - i * 2
            if sc > bs then best, bs = rec, sc end
        end
    end
    return best
end

function fn.backtrack_apply(ent, rec)
    if not rec then return end
    local v1, v2 = rec.vel[1], rec.vel[2]
    local spd = m_sqrt(v1 * v1 + v2 * v2)
    if spd < 5 then return end
    local my = m_deg(m_atan2(v2, v1))
    local by = e_prop(ent, "m_flLowerBodyYawTarget") or 0
    local side = fn.norm(my - by) > 0 and 1 or -1
    p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", true); p_set(ent, "Force Body Yaw Value", by + side * 25)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Baim if lethal
-- ═══════════════════════════════════════════════════════════════════════════
local baim_on, baim_snap = false, nil
local BAIM_HB = {2, 3, 4, 5, 6}
function fn.baim_release()
    if baim_on and ref.forcebaim and baim_snap ~= nil then fn.set(ref.forcebaim, baim_snap) end
    baim_on, baim_snap = false, nil
end
function fn.baim_update()
    if g_tick() % 2 ~= 0 then return end
    if not fn.get(m.rage.resolver, true) then fn.baim_release(); return end
    local me = e_local(); if not me or not e_alive(me) then fn.baim_release(); return end
    local ex, ey, ez = c_eye(); if not ex then return end
    local tgt = c_threat()
    if not tgt or not e_alive(tgt) or e_dormant(tgt) then fn.baim_release(); return end
    local hp = e_prop(tgt, "m_iHealth") or 0
    local lethal = false
    if hp > 0 then
        for i = 1, 5 do
            local hx, hy, hz = e_hitbox(tgt, BAIM_HB[i])
            if hx then
                local h, d = c_trace_b(me, ex, ey, ez, hx, hy, hz)
                if h == tgt and d and d >= hp then lethal = true; break end
            end
        end
    end
    if lethal then
        if not baim_on then baim_snap = ref.forcebaim and fn.get(ref.forcebaim); baim_on = true end
        if ref.forcebaim then fn.ovr(ref.forcebaim, true) end
    else fn.baim_release() end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Tickbase defensive + DT charge
-- ═══════════════════════════════════════════════════════════════════════════
function fn.in_defensive() local d = mg.tb.diff; return d ~= nil and d <= -1 and d >= -14 end
function fn.tb_depth() local d = mg.tb.diff; if d == nil or d >= 0 then return 0 end; return -d end
function fn.tb_charged() local d = mg.tb.diff; return d == nil or d >= 0 end
function fn.tb_reset() mg.tb.max = nil; mg.tb.diff = nil; mg.tb.cmd = nil; mg.tb.depth = 0 end

function fn.dt_charged()
    local lp = e_local()
    if not lp or not e_alive(lp) then return false end
    if ref.fakeduck and fn.hotkey_active(ref.fakeduck[2]) then return false end
    local wep = e_weapon(lp); if not wep then return false end
    local na = e_prop(lp, "m_flNextAttack")
    local npa = e_prop(wep, "m_flNextPrimaryAttack")
    if type(na) ~= "number" or type(npa) ~= "number" then return false end
    local ct = g_curtime()
    return (na + 0.01) - ct < 0 and (npa + 0.01) - ct < 0
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Player state
-- ═══════════════════════════════════════════════════════════════════════════
function fn.player_state(cmd)
    local lp = e_local(); if not lp then return "Shared" end
    local vx, vy = e_prop(lp, "m_vecVelocity")
    vx, vy = vx or 0, vy or 0
    local flags = e_prop(lp, "m_fFlags") or 0
    local velocity = m_sqrt(vx * vx + vy * vy)
    local grounded = b_band(flags, CY.FL_GROUND) ~= 0
    local ducked = (e_prop(lp, "m_flDuckAmount") or 0) > 0.7
    local duckcheck = ducked or (ref.fakeduck and fn.hotkey_active(ref.fakeduck[2]))
    local slowwalk = ref.slow[1] and fn.hotkey_active(ref.slow[2])
    if not grounded and duckcheck then return "Aerobic+"
    elseif not grounded then return "Aerobic"
    elseif duckcheck and velocity > 10 then return "Sneaking"
    elseif duckcheck then return "Ducking"
    elseif grounded and slowwalk and velocity > 10 then return "Walking"
    elseif velocity > 5 then return "Running"
    else return "Standing" end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Anti-aim builder
-- ═══════════════════════════════════════════════════════════════════════════
local yaw_direction, last_manual = 0, 0
local aa_invert, aa_invert_tick, aa_to_jitter, aa_delayed_flick = false, 0, false, false
local aam = {jitter = 0, delay = 0, switch = false, mode = false, swaytimer = 0, spintimer = 0, desyncswitch = false, micro = false, microtick = 0}

function fn.run_direction()
    if fn.get(m.aa.freestand) then
        for _, v in ipairs(ref.AA.freestand) do fn.ovr(v, true) end
    end
    if yaw_direction ~= 0 and ref.AA.freestand[1] then fn.ovr(ref.AA.freestand[1], false) end
    local now = g_curtime()
    if fn.get(m.aa.manual_right) and last_manual + 0.2 < now then yaw_direction = yaw_direction == 90 and 0 or 90; last_manual = now
    elseif fn.get(m.aa.manual_left) and last_manual + 0.2 < now then yaw_direction = yaw_direction == -90 and 0 or -90; last_manual = now
    elseif fn.get(m.aa.manual_forward) and last_manual + 0.2 < now then yaw_direction = yaw_direction == 180 and 0 or 180; last_manual = now
    elseif last_manual > now then last_manual = now end
end

function fn.aa_get_invert(delay, cmd)
    if g_tick() > aa_invert_tick + delay then
        if cmd.chokedcommands == 0 then aa_invert = not aa_invert; aa_invert_tick = g_tick() end
    end
    if g_tick() < aa_invert_tick then aa_invert_tick = g_tick() end
    return aa_invert
end

function fn.choose_aa(cmd)
    local st = fn.player_state(cmd)
    mg.state = st
    local id = CIDX[st] or 1
    if id ~= 1 and not fn.get(aa[id].enabled) then id = 1 end
    return aa[id], id
end

local aa_id = 1

local DEF_RISK = {Safest = -4, Low = -3, Medium = -2, High = -1}
local LAGCOMP_TELEPORT_DIST = 64

function fn.fakelag(cmd, lp)
    mg.lc_broken = false
    if not fn.get(m.aa.fl_active) then return end
    if not lp or not e_alive(lp) then return end
    for _, v in ipairs(ref.FL.enabled) do fn.ovr(v, false) end
    fn.ovr(ref.FL.amount, "Maximum")

    local choked = cmd.chokedcommands
    local dloc_delta = vector(e_origin(lp)):dist(mg.declaredloc)
    local mode = fn.get(m.aa.fl_mode, "Static")
    local limit = fn.get(m.aa.fl_limit, 14)
    local lo = m_min(fn.get(m.aa.fl_min, 1), limit)
    local want = limit
    if mode == "Adaptive" then want = m_floor(lo + fn.clamp(mg.lp.speedxy / 250, 0, 1) * (limit - lo) + 0.5)
    elseif mode == "Random" then want = m_random(lo, limit)
    elseif mode == "Peek" then want = ((ref.autopeek[2] and fn.hotkey_active(ref.autopeek[2])) or mg.lp.speedxy > 40) and limit or lo end
    if mg.exploit ~= "" then want = m_min(want, 1) end
    want = fn.clamp(want, 1, 16)
    local send = choked >= want

    local brk = fn.get(m.aa.fl_breaklc)
    if brk then
        local cond = m.aa.fl_breakcond
        local list = fn.get(cond, {})
        local grounded = b_band(e_prop(lp, "m_fFlags") or 0, CY.FL_GROUND) ~= 0
        local allowed = (fn.contains(list, "Moving") and mg.lp.speedxy > 40)
            or (fn.contains(list, "In Air") and not grounded)
            or (fn.contains(list, "Peeking") and ref.autopeek[2] and fn.hotkey_active(ref.autopeek[2]))
            or (fn.contains(list, "Defensive") and fn.in_defensive())
        if allowed then
            local target = fn.get(m.aa.fl_breakdist, 66)
            if dloc_delta < target then send = false else send = true; cmd.no_choke = true; mg.lc_broken = true end
        end
    end

    if choked >= 15 then send = true end
    if mg.shotbool and not (brk and fn.get(m.aa.fl_breakshot)) then send = true; cmd.no_choke = true end
    if not mg.lc_broken and not brk and dloc_delta > LAGCOMP_TELEPORT_DIST then send = true; cmd.no_choke = true end
    cmd.allow_send_packet = send
end

function fn.coco_def_yaw(A, yaw)
    local dy = fn.get(A.def_yaw)
    if dy == "Forward" then return 180 end
    if dy == "Opposite" then return fn.norm(yaw + 180) end
    if dy == "Jitter" then return aam.desyncswitch and fn.get(A.def_amount, 0) or -fn.get(A.def_amount, 0) end
    return nil
end

function fn.setup_aa(cmd)
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local A, id = fn.choose_aa(cmd)
    aa_id = id
    if not fn.get(A.enabled) then return end

    local tick_delay = fn.get(A.jit_delaymin) and 1 or 1
    if g_tick() % 2 == 0 then aa_to_jitter = not aa_to_jitter end
    for _, v in ipairs(ref.AA.jitter) do fn.ovr(v, v == ref.AA.jitter[1] and "Off" or 0) end
    if fn.get(m.aa.body_jitter_type) ~= "Invert Jitter Desync" then mg.head_peek = 0 end

    fn.fakelag(cmd, lp)
    if cmd.allow_send_packet then mg.declaredloc = vector(e_origin(lp)) end

    local desync_pose = (e_prop(lp, "m_flPoseParameter", 11) or 0.5) * 120 - 60
    local desync_side = desync_pose > 0

    local yaw = 0
    if fn.get(A.yaw) == "Static" then yaw = fn.randomize(fn.get(A.yaw_static, 0), fn.get(A.yaw_random, 0))
    elseif fn.get(A.yaw) == "Switch" then yaw = fn.randomize(desync_side and fn.get(A.yaw_left, 0) or fn.get(A.yaw_right, 0), fn.get(A.yaw_random, 0)) end

    aa_invert = fn.aa_get_invert(tick_delay, cmd)

    -- CocoYaw modifiers
    aam.jitter = (aam.switch and -1 or 1) * fn.randf(fn.get(A.jit_min, 0), fn.get(A.jit_max, 0))
    local sa, spd = fn.get(A.sway_amount, 0), fn.get(A.sway_speed, 0)
    if aam.swaytimer >= sa then aam.mode = true elseif aam.swaytimer <= -sa then aam.mode = false end
    aam.swaytimer = aam.swaytimer + (aam.mode and -spd or spd)
    aam.spintimer = aam.spintimer >= fn.get(A.spin_amount, 0) and 0 or (aam.spintimer + fn.get(A.spin_speed, 0))
    local mods = fn.get(A.mods, {})
    if fn.contains(mods, "Jitter") then yaw = yaw + aam.jitter end
    if fn.contains(mods, "Sway") then yaw = yaw + aam.swaytimer end
    if fn.contains(mods, "Spin") then yaw = yaw + aam.spintimer end
    local slow = fn.contains(mods, "Slow Jitter")
    local speriod = slow and fn.get(A.slow_period, 3) or 3
    if slow then local amt = fn.get(A.slow_amount, 45); yaw = yaw + (mg.fl_phase < speriod and amt * 0.5 or -amt * 0.5) end

    local mod = fn.get(A.yaw_modifier)
    local mv, mr = fn.get(A.yaw_modifier_value, 0), fn.get(A.yaw_modifier_random, 0)
    if mod == "Center" then yaw = yaw + fn.randomize(aa_to_jitter and -mv / 2 or mv / 2, mr)
    elseif mod == "Offset" then yaw = yaw + (aa_to_jitter and fn.randomize(mv, mr) or 0)
    elseif mod == "Random" then yaw = yaw + fn.randomize(m_random(-mv, mv), mr)
    elseif mod == "3-Way" then local p = g_tick() % 3; if p == 0 then yaw = yaw + fn.randomize(-mv, mr) elseif p == 2 then yaw = yaw + fn.randomize(mv, mr) end
    elseif mod == "5-Way" then
        local p = g_tick() % 5
        if p == 0 then yaw = yaw + fn.randomize(-mv, mr) elseif p == 1 then yaw = yaw + fn.randomize(-mv / 2, mr)
        elseif p == 3 then yaw = yaw + fn.randomize(mv / 2, mr) elseif p == 4 then yaw = yaw + fn.randomize(mv, mr) end
    end

    local in_def = fn.in_defensive()
    mg.indefensive, mg.tb.depth = in_def, fn.tb_depth()

    -- desync on choked packet
    if cmd.allow_send_packet then
        if aam.delay >= m_random(fn.get(A.jit_delaymin, 0), fn.get(A.jit_delaymax, 0)) then aam.delay = 0; aam.switch = not aam.switch else aam.delay = aam.delay + 1 end
    elseif not in_def then
        local dtp = fn.get(A.desync)
        if dtp ~= "Off" then
            yaw = mg.declaredyaw
            aam.desyncswitch = not aam.desyncswitch
            local amount = fn.get(A.desync_amount, 60)
            if dtp == "Static" then
                yaw = yaw + amount * (fn.get(m.aa.desync_inverter) and 1 or -1)
            else
                local side = aam.desyncswitch and 1 or -1
                local jt = fn.get(m.aa.body_jitter_type)
                if jt == "Desync" then side = aam.switch and 1 or -1 end
                if jt == "Invert Jitter Side" then side = -side end
                if jt == "Invert Jitter Desync" then
                    side = -(aam.switch and 1 or -1)
                    if fn.get(m.aa.head_peek_ceil) then amount = m_max(amount, mg.own_max or MAX_YAW_FALLBACK) end
                    mg.head_peek = side
                end
                yaw = yaw + amount * side
            end
        end
    end

    -- body yaw
    if fn.get(A.bodyyaw) then
        if slow and not cmd.allow_send_packet then
            fn.ovr(ref.AA.bodyyaw[1], "Static"); fn.ovr(ref.AA.bodyyaw[2], mg.fl_phase < speriod and 59 or -59)
        elseif not fn.get(A.body_jitter) then fn.ovr(ref.AA.bodyyaw[1], "Opposite")
        else fn.ovr(ref.AA.bodyyaw[1], "Static"); fn.ovr(ref.AA.bodyyaw[2], aa_invert and -91 or 91) end
    else fn.ovr(ref.AA.bodyyaw[1], "Off"); fn.ovr(ref.AA.bodyyaw[2], 0) end

    if fn.get(A.fs_bodyyaw) then fn.ovr(ref.AA.fsbodyyaw, true) else fn.ovr(ref.AA.fsbodyyaw, false) end

    -- extended defensive
    local want_ext = fn.get(m.aa.ext_def) or (fn.get(m.aa.ext_def_hit) and mg.hittable_any)
    if mg.tb.diff == nil or mg.tb.diff >= 0 then mg.ext_fired = false end
    if want_ext and ref.doubletap[2] and fn.hotkey_active(ref.doubletap[2]) then
        cmd.force_defensive = true
        local risk = DEF_RISK[fn.get(m.aa.defensive_risk, "High")] or -1
        if not mg.ext_fired and mg.tb.diff ~= nil and mg.tb.diff <= risk then
            fn.ovr(ref.doubletap[1], false); cmd.force_defensive = false; mg.ext_fired = true
        end
    else mg.ext_fired = false end

    if fn.get(A.force_def) and fn.get(A.defensive) then cmd.force_defensive = true end
    if in_def then cmd.force_defensive = true end

    -- disablers
    if fn.contains(fn.get(m.aa.disablers, {}), "Disable on Warmup") and entity.get_game_rules and e_prop(entity.get_game_rules(), "m_bWarmupPeriod") == 1 then
        fn.ovr(ref.AA.yaw[1], "Off"); for _, v in ipairs(ref.AA.pitch) do fn.ovr(v, "Off") end; return
    end
    if fn.contains(fn.get(m.aa.disablers, {}), "Disable on Round End") and round_ended then
        fn.ovr(ref.AA.yaw[1], "Off"); for _, v in ipairs(ref.AA.pitch) do fn.ovr(v, "Off") end; return
    end

    local flick_on = fn.get(m.aa.flick) and fn.get(m.aa.manual_forward)

    -- defensive AA
    if fn.get(A.defensive) and in_def and yaw_direction == 0 and not flick_on then
        local dp = fn.get(A.def_pitch)
        local dpv = 89
        if dp == "Down" then dpv = 89 elseif dp == "Up" then dpv = -89 elseif dp == "Zero" then dpv = 0
        elseif dp == "Random" then dpv = m_random(-89, 89)
        elseif dp == "Switch" then dpv = fn.randomize(aa_to_jitter and fn.get(A.def_pitch_jit1, 0) or fn.get(A.def_pitch_jit2, 0), fn.get(A.def_pitch_random, 0))
        elseif dp == "Vladick" then dpv = fn.randomize(fn.map_val(m_abs(g_realtime() % 0.3 - 0.15), 0, 0.15, -89, 89), fn.get(A.def_pitch_random, 0))
        elseif dp == "3-Way" then local p = g_tick() % 3; if p == 0 then dpv = fn.randomize(-fn.get(A.def_pitch_value, 0), fn.get(A.def_pitch_random, 0)) elseif p == 1 then dpv = 0 else dpv = fn.randomize(fn.get(A.def_pitch_value, 0), fn.get(A.def_pitch_random, 0)) end
        elseif dp == "5-Way" then local p = g_tick() % 5; local dv, dr = fn.get(A.def_pitch_value, 0), fn.get(A.def_pitch_random, 0)
            if p == 0 then dpv = fn.randomize(-dv, dr) elseif p == 1 then dpv = fn.randomize(-dv / 2, dr) elseif p == 2 then dpv = 0 elseif p == 3 then dpv = fn.randomize(dv / 2, dr) else dpv = fn.randomize(dv, dr) end
        elseif dp == "Spin" then dpv = fn.randomize(-m_fmod(g_curtime() * (fn.get(A.def_pitch_spin, 1) * 360), 178) + 89, fn.get(A.def_pitch_random, 0))
        elseif dp == "Custom" then dpv = fn.get(A.def_pitch_value, 0)
        elseif dp == "Off" then dpv = nil end

        local dy = fn.get(A.def_yaw)
        local dyv = fn.norm(yaw)
        local coco = fn.coco_def_yaw(A, yaw)
        if coco ~= nil then dyv = coco
        elseif dy == "Static" then dyv = fn.get(A.def_yaw_value, 0)
        elseif dy == "Switch" then dyv = fn.norm(fn.randomize(aa_to_jitter and fn.get(A.def_yaw_left, 0) or fn.get(A.def_yaw_right, 0), fn.get(A.def_yaw_random, 0)))
        elseif dy == "3-Way" then local p = g_tick() % 3; local dv, dr = fn.get(A.def_yaw_value, 0), fn.get(A.def_yaw_random, 0); if p == 0 then dyv = fn.norm(fn.randomize(-dv, dr)) elseif p == 1 then dyv = 0 else dyv = fn.norm(fn.randomize(dv, dr)) end
        elseif dy == "5-Way" then local p = g_tick() % 5; local dv, dr = fn.get(A.def_yaw_value, 0), fn.get(A.def_yaw_random, 0)
            if p == 0 then dyv = fn.norm(fn.randomize(-dv, dr)) elseif p == 1 then dyv = fn.norm(fn.randomize(-dv / 2, dr)) elseif p == 2 then dyv = 0 elseif p == 3 then dyv = fn.norm(fn.randomize(dv / 2, dr)) else dyv = fn.norm(fn.randomize(dv, dr)) end
        elseif dy == "Vladick" then dyv = fn.norm(fn.randomize(fn.map_val(m_abs(g_realtime() % 0.3 - 0.15), 0, 0.15, -180, 180), fn.get(A.def_yaw_random, 0)))
        elseif dy == "Spin" then dyv = fn.norm(fn.randomize(-m_fmod(g_curtime() * (fn.get(A.def_yaw_spin, 1) * 360), 360) + 180, fn.get(A.def_yaw_random, 0))) end

        if dpv ~= nil then fn.ovr(ref.AA.pitch[1], "Custom"); if ref.AA.pitch[2] then fn.ovr(ref.AA.pitch[2], fn.wrap_pitch(dpv)) end end
        fn.ovr(ref.AA.yaw[1], "180"); if ref.AA.yaw[2] then fn.ovr(ref.AA.yaw[2], dyv) end
        fn.ovr(ref.AA.yawbase, fn.get(A.yaw_base))
    elseif flick_on then
        cmd.force_defensive = cmd.command_number % 2 == 0
        if g_tick() % 4 == 0 and in_def then aa_delayed_flick = not aa_delayed_flick end
        local ft = fn.get(m.aa.flick_type, "Left")
        local fval = ft == "Right" and 90 or (ft == "Left" and -90 or fn.get(m.aa.flick_value, 0))
        fn.ovr(ref.AA.yaw[1], "180"); fn.ovr(ref.AA.pitch[1], "Down")
        if ref.AA.yaw[2] then fn.ovr(ref.AA.yaw[2], in_def and fval or 4) end
        fn.ovr(ref.AA.bodyyaw[1], "Static"); fn.ovr(ref.AA.bodyyaw[2], aa_delayed_flick and -91 or 91)
    else
        -- normal
        if fn.contains(fn.get(m.aa.tweaks, {}), "Static on Manual") and yaw_direction ~= 0 then
            if ref.AA.yaw[2] then fn.ovr(ref.AA.yaw[2], yaw_direction) end
            fn.ovr(ref.AA.yawbase, "Local view")
            fn.ovr(ref.AA.bodyyaw[1], "Off"); fn.ovr(ref.AA.bodyyaw[2], 0)
        elseif yaw_direction ~= 0 then
            if ref.AA.yaw[2] then fn.ovr(ref.AA.yaw[2], fn.norm(yaw + yaw_direction)) end
            fn.ovr(ref.AA.yaw[1], "180"); fn.ovr(ref.AA.pitch[1], "Down"); fn.ovr(ref.AA.yawbase, "Local view")
        else
            if ref.AA.yaw[2] then fn.ovr(ref.AA.yaw[2], fn.norm(yaw)) end
            fn.ovr(ref.AA.yaw[1], "180")
            local pm = fn.get(A.pitch)
            if pm == "Random" then fn.ovr(ref.AA.pitch[1], "Custom"); if ref.AA.pitch[2] then fn.ovr(ref.AA.pitch[2], m_random(-89, 89)) end
            elseif pm ~= "Off" then fn.ovr(ref.AA.pitch[1], pm)
            else fn.ovr(ref.AA.pitch[1], "Off") end
            fn.ovr(ref.AA.yawbase, fn.get(A.yaw_base))
        end
        if fn.contains(fn.get(m.aa.tweaks, {}), "Static on TP/Recharge") and in_def then
            local ds = fn.get(m.aa.desync_inverter) and 1 or -1
            if ref.AA.yaw[2] then
                if mg.fsyaw then fn.ovr(ref.AA.yaw[2], mg.fsyaw + (aa_to_jitter and ds * 30 or -ds * 30))
                else fn.ovr(ref.AA.yaw[2], aa_to_jitter and ds * 40 or -ds * 40) end
            end
        end
    end

    -- anti backstab
    if fn.contains(fn.get(m.aa.tweaks, {}), "Anti Backstab") then
        local ox, oy, oz = e_prop(lp, "m_vecOrigin")
        local players = e_players(true)
        for i = 1, #players do
            local w = e_weapon(players[i])
            if w and e_class(w) == "CKnife" then
                local ex, ey, ez = e_prop(players[i], "m_vecOrigin")
                if ex and ox then
                    local dist = m_sqrt((ex - ox) ^ 2 + (ey - oy) ^ 2 + (ez - oz) ^ 2)
                    if dist <= 250 then if ref.AA.yaw[2] then fn.ovr(ref.AA.yaw[2], 180) end; fn.ovr(ref.AA.yawbase, "At targets") end
                end
            end
        end
    end

    -- edge yaw on fd
    if fn.contains(fn.get(m.aa.tweaks, {}), "Edge Yaw on FD") then
        fn.ovr(ref.AA.edgeyaw, (ref.fakeduck and fn.hotkey_active(ref.fakeduck[2])) or false)
    else fn.ovr(ref.AA.edgeyaw, false) end

    -- micro movement
    if fn.contains(fn.get(m.aa.tweaks, {}), "Micro Movement") and mg.lp.speedxy < 2 and cmd.sidemove == 0 and cmd.forwardmove == 0 then
        aam.microtick = aam.microtick + 1; aam.micro = not aam.micro
        cmd.sidemove = (aam.micro and 1 or -1) * (mg.lp.duck and 2 or 1.1) * (1 + (aam.microtick % 7) * 0.02)
    end

    -- leg breaker
    if fn.get(m.aa.leg_breaker) then fn.ovr(ref.leg, cmd.allow_send_packet and "Always slide" or "Never slide") end

    -- roll on sent packet
    local roll_ok = not fn.contains(fn.get(m.aa.tweaks, {}), "Disable Roll on Auto Peek") or not (ref.autopeek[2] and fn.hotkey_active(ref.autopeek[2]))
    fn.ovr(ref.AA.roll, 0)
    if cmd.allow_send_packet then
        if roll_ok then cmd.roll = fn.get(A.roll, 0) end
        mg.declaredyaw = yaw
    else
        cmd.roll = 0; mg.fakeyaw = yaw
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Rage value request arbiter (mp / hc / dmg / dthc), single writer
-- ═══════════════════════════════════════════════════════════════════════════
local HS = {
    PROFILE = {
        AWP = {mp = 60, hc = 60, sf = 0.25, air_hc = 48, dmg = 100, dt_base = 62},
        ["SSG 08"] = {mp = 82, hc = 56, sf = 0.30, air_hc = 50, dmg = 100, dt_base = 56},
        ["G3SG1 / SCAR-20"] = {mp = 48, hc = 38, sf = 0.40, air_hc = 40, dt_base = 46},
        ["Desert Eagle"] = {mp = 75, hc = 50, sf = 0.35, air_hc = 45, dt_base = 50},
        ["R8 Revolver"] = {mp = 55, hc = 62, sf = 0.30, air_hc = 48, dt_base = 58},
        Rifle = {mp = 70, hc = 52, sf = 0.55, air_hc = 45, dt_base = 42},
        SMG = {mp = 85, hc = 45, sf = 0.80, dt_base = 34},
        Shotgun = {mp = 100, hc = 40, sf = 1.00, dt_base = 30},
        ["Machine gun"] = {mp = 85, hc = 48, sf = 0.75, dt_base = 36},
        Pistol = {mp = 90, hc = 60, sf = 0.60, air_hc = 52, dt_base = 40},
        Zeus = {mp = 100, hc = 30, sf = 1.00, dt_base = 20},
        Global = {mp = 70, hc = 55, sf = 0.55, air_hc = 48, dt_base = 44},
    },
    SCOPED = {AWP = true, ["SSG 08"] = true, ["G3SG1 / SCAR-20"] = true, Rifle = true},
    bk_mp = {}, bk_hc = {}, bk_dmg = {}, bk_dthc = {}, last = {}, dt_learn = {},
    cur_wtype = "Global", was_hs = false, was_dthc = false,
    dt_mode = "Offensive", dt_score = 0, dt_mode_t = 0,
    req = {mp = nil, hc = nil, hc_prio = -1, hc_pen = 0, hc_floor = 0, dmg = nil, dthc = nil},
}
local WTYPE_CLASS = {
    CWeaponAWP = "AWP", CWeaponSSG08 = "SSG 08", CWeaponSCAR20 = "G3SG1 / SCAR-20", CWeaponG3SG1 = "G3SG1 / SCAR-20",
    CWeaponTaser = "Zeus", CAK47 = "Rifle", CWeaponAUG = "Rifle", CWeaponSG556 = "Rifle", CWeaponFamas = "Rifle",
    CWeaponGalilAR = "Rifle", CWeaponM4A1 = "Rifle", CWeaponM4A1Silencer = "Rifle",
    CWeaponMP7 = "SMG", CWeaponMP9 = "SMG", CWeaponMAC10 = "SMG", CWeaponUMP45 = "SMG", CWeaponP90 = "SMG", CWeaponBizon = "SMG", CWeaponMP5SD = "SMG",
    CWeaponNOVA = "Shotgun", CWeaponXM1014 = "Shotgun", CWeaponSawedoff = "Shotgun", CWeaponMag7 = "Shotgun",
    CWeaponM249 = "Machine gun", CWeaponNegev = "Machine gun",
    CWeaponGlock = "Pistol", CWeaponUSP = "Pistol", CWeaponUSPSilencer = "Pistol", CWeaponHKP2000 = "Pistol",
    CWeaponP250 = "Pistol", CWeaponFiveSeven = "Pistol", CWeaponTec9 = "Pistol", CWeaponElite = "Pistol", CWeaponCZ75a = "Pistol",
}
function fn.weapon_type(wep)
    if not wep then return "Global" end
    local cn = e_class(wep)
    if cn == "CDEagle" then return (e_prop(wep, "m_iItemDefinitionIndex") == 64) and "R8 Revolver" or "Desert Eagle" end
    return WTYPE_CLASS[cn] or "Global"
end

function fn.hc_request(v, prio) if v == nil then return end; if prio > HS.req.hc_prio then HS.req.hc = v; HS.req.hc_prio = prio end end
function fn.hc_penalty(v) if v > HS.req.hc_pen then HS.req.hc_pen = v end end
function fn.rage_reset()
    local r = HS.req
    r.mp, r.hc, r.hc_prio, r.hc_pen, r.hc_floor, r.dmg, r.dthc = nil, nil, -1, 0, 0, nil, nil
end
function fn.rage_invalidate() HS.last = {} end
function fn.rage_dirty(r, w, v)
    local t = HS.last[r]; if not t then t = {}; HS.last[r] = t end
    if t[w] == v then return false end; t[w] = v; return true
end
function fn.rage_backup_set(bk, r, w, v)
    if not r then return end
    if bk[w] == nil then bk[w] = fn.get(r) end
    fn.set(r, v)
end
function fn.rage_flush()
    if not ref.wtype then return end
    local w, r = HS.cur_wtype, HS.req
    local hc = r.hc
    -- the spread floor lifts whatever the gate would otherwise be, including the
    -- user's own slider when adaptive hitscale is switched off
    if r.hc_floor and r.hc_floor > 0 then
        hc = m_max(hc or HS.bk_hc[w] or fn.get(ref.hitchance) or 0, r.hc_floor)
    end
    if hc ~= nil then hc = fn.clamp(m_floor(hc + r.hc_pen), 0, 100) end
    local d_mp = r.mp ~= nil and fn.rage_dirty(ref.mpscale, w, r.mp)
    local d_hc = hc ~= nil and fn.rage_dirty(ref.hitchance, w, hc)
    local d_dmg = r.dmg ~= nil and fn.rage_dirty(ref.mindmg, w, r.dmg)
    local d_dthc = r.dthc ~= nil and ref.dthc and fn.rage_dirty(ref.dthc, w, r.dthc)
    if not (d_mp or d_hc or d_dmg or d_dthc) then return end
    local prev = fn.get(ref.wtype)
    local switched = prev ~= w
    if switched then fn.set(ref.wtype, w) end
    if d_mp then fn.rage_backup_set(HS.bk_mp, ref.mpscale, w, r.mp) end
    if d_hc then fn.rage_backup_set(HS.bk_hc, ref.hitchance, w, hc) end
    if d_dmg then fn.rage_backup_set(HS.bk_dmg, ref.mindmg, w, r.dmg) end
    if d_dthc then fn.rage_backup_set(HS.bk_dthc, ref.dthc, w, r.dthc) end
    if switched then fn.set(ref.wtype, prev) end
end
function fn.rage_restore_one(bk, r)
    if not r or next(bk) == nil then return end
    local prev = fn.get(ref.wtype)
    for w, v in pairs(bk) do fn.set(ref.wtype, w); fn.set(r, v); bk[w] = nil end
    fn.set(ref.wtype, prev)
end
function fn.rage_restore_all()
    fn.rage_restore_one(HS.bk_mp, ref.mpscale); fn.rage_restore_one(HS.bk_hc, ref.hitchance)
    fn.rage_restore_one(HS.bk_dmg, ref.mindmg); fn.rage_restore_one(HS.bk_dthc, ref.dthc)
    fn.rage_invalidate()
end

-- Minimum hit chance the shot must clear before dispersion makes it a coin flip.
--
-- The old curve topped out around 54 for a scout even at max strength, so it
-- never bound against the 52-62 the adaptive path was writing and every spread
-- miss went out unchallenged. Base raised, the lethal discount cut from 0.75 to
-- 0.93 (it applied to every one-shot weapon permanently, gutting the floor on
-- exactly the guns that need it), and the ceiling raised to 95.
function fn.spread_floor(dist, speed, air, sf, lethal)
    if not fn.get(m.rage.spread, true) then return 0 end
    local f = 52 + fn.clamp(dist / 3000, 0, 1) * 30 + fn.clamp(speed / 250, 0, 1) * 20
    if air then f = f + 15 end
    f = f * (0.90 + sf * 0.20)
    if lethal then f = f * 0.93 end
    return fn.clamp(f * fn.get(m.rage.spread_strength, 100) * 0.01, 0, 95)
end

function fn.dt_shift()
    local lp = e_local(); if not lp then return 0 end
    local tb = e_prop(lp, "m_nTickBase"); if type(tb) ~= "number" then return 0 end
    local lat = c_latency() or 0
    return m_floor(tb - g_tick() - 3 - (lat * TICK_INV) * 0.5 + 0.5 * (lat * 10))
end

function fn.adaptive_hitscale(me, w, prof, dist, self_air)
    if not fn.get(m.rage.hs) then return end
    local mp, hc = prof.mp, prof.hc
    local tgt = c_threat()
    if not tgt or not e_alive(tgt) then HS.req.mp = mp; fn.hc_request(hc, 1); return end
    local dn = fn.clamp(dist / 3000, 0, 1)
    local e = ents[tgt]; local pd, h, pr = e and e.p, e and e.h, e and e.pr
    local resolved = pr and pr.r or false
    local stage = pr and pr.s or 1
    local conf = h and h.cf or 0
    local defen = pd and pd.def or false
    local sway = pd and pd.swd or false
    local onshot = pd and pd.ovalid or false
    local direct = pd and (pd.hasanim or pd.pbody_ok) or false
    local tair = pd and (pd.st == ST.AIR or pd.st == ST.AIR_CROUCH) or false
    local tmov = pd and (pd.st == ST.MOVING or pd.st == ST.CROUCH_MOVING or pd.st == ST.RUSHING) or false
    if defen or onshot then mp = mp - 15
    elseif direct and resolved and conf > 40 then mp = mp - 12
    elseif direct then mp = mp - 6
    elseif resolved and conf > 40 then mp = mp - 10
    elseif sway then mp = mp + 20
    elseif stage <= 2 then mp = mp + 12 end
    if tair then mp = mp + 10 end
    if tmov then mp = mp + 6 end
    if not direct then mp = mp + 8 end
    mp = fn.clamp(m_floor(mp + dn * 25 * prof.sf), 24, 100)
    if defen or onshot then hc = hc - 8
    elseif direct and resolved and conf > 40 then hc = hc - 7
    elseif direct then hc = hc - 3
    elseif resolved and conf > 40 then hc = hc - 5
    elseif sway then hc = hc + 12
    elseif stage <= 2 then hc = hc + 8 end
    if self_air then hc = prof.air_hc and prof.air_hc + (hc - prof.hc) or hc + 15 end
    if mg.lp.speedxy > 60 and not self_air then hc = hc + 6 end
    if HS.SCOPED[w] and e_prop(me, "m_bIsScoped") == 0 then hc = hc + 20 end
    if tair then hc = hc + 5 end
    hc = hc + dn * 18
    if not fn.tb_charged() then fn.hc_penalty(m_min(fn.tb_depth(), 14) * 2) end
    if pd and pd.tele then hc = hc + 8 end
    local hp = e_prop(tgt, "m_iHealth") or 100
    local lethal = prof.dmg ~= nil or (hp > 0 and hp <= 40)
    -- spread floor is applied globally in rage_flush so it also covers the case
    -- where adaptive hitscale is off
    HS.req.mp = mp
    fn.hc_request(fn.clamp(m_floor(hc), 0, 100), 1)
    if fn.get(m.rage.hs_dmg) and not (ref.mindmg_override[2] and fn.hotkey_active(ref.mindmg_override[2])) then
        local dmg
        if hp <= 0 then dmg = nil
        elseif prof.dmg then dmg = fn.clamp(m_min(prof.dmg, hp), 1, 100)
        elseif defen or onshot or (resolved and conf > 40) then dmg = fn.clamp(hp, 1, 100)
        elseif sway or stage <= 2 then dmg = fn.clamp(m_floor(hp * 0.45), 1, 100)
        else dmg = fn.clamp(m_floor(hp * 0.7), 1, 100) end
        if dmg then HS.req.dmg = dmg end
    end
end

function fn.adaptive_dthc(me, w, prof, dist, self_air)
    if not ref.dthc or not fn.get(m.rage.dthc) then return end
    if not (ref.doubletap[1] and fn.get(ref.doubletap[1])) or not (ref.doubletap[2] and fn.hotkey_active(ref.doubletap[2])) then return end
    local base = mg.indefensive and fn.get(m.rage.dthc_def, 55) or fn.get(m.rage.dthc_off, 30)
    if not fn.dt_charged() then base = base + fn.get(m.rage.dthc_uncharged, 40) end
    if not fn.tb_charged() then base = base + m_min(fn.tb_depth(), 14) * 2.5 end
    if fn.dt_shift() > -3 then base = base + 10 end
    local lat_ms = (c_latency() or 0) * 1000
    if lat_ms > 80 then base = base + fn.clamp((lat_ms - 80) / 120, 0, 1) * 14 end
    base = base + fn.clamp(dist / 3000, 0, 1) * 20 * (0.6 + (prof.sf or 0.55) * 0.8)
    if self_air then base = base + 15 end
    if HS.SCOPED[w] and e_prop(me, "m_bIsScoped") == 0 then base = base + 14 end
    local tgt = c_threat()
    if tgt and e_alive(tgt) then
        local e = ents[tgt]; local pd, h, pr = e and e.p, e and e.h, e and e.pr
        local direct = pd and (pd.hasanim or pd.pbody_ok) or false
        local conf = h and h.cf or 0
        local resolved = pr and pr.r or false
        if pd and (pd.def or pd.ovalid) then base = base - 14
        elseif direct and resolved and conf > 40 then base = base - 11
        elseif direct then base = base - 5
        elseif resolved and conf > 40 then base = base - 8
        elseif pd and pd.swd then base = base + 15
        elseif pr and pr.s and pr.s <= 2 then base = base + 9 end
        if not direct then base = base + 6 end
        if pd and (pd.st == ST.AIR or pd.st == ST.AIR_CROUCH) then base = base + 8 end
        if pd and pd.tele then base = base + 10 end
    else base = base + 10 end
    if fn.get(m.rage.dthc_learn) then local t = HS.dt_learn[w]; if t then base = base + t.bias end end
    HS.req.dthc = fn.clamp(m_floor(base), 0, 100)
end

function fn.dt_auto()
    if DT_MODE == nil or not fn.get(m.rage.dt_auto) then return end
    if not (ref.doubletap[1] and fn.get(ref.doubletap[1])) then return end
    local me = e_local(); if not me or not e_alive(me) then return end
    local score = 0
    if mg.indefensive then score = score + 40 end
    if fn.get(m.aa.ext_def) or (fn.get(m.aa.ext_def_hit) and mg.hittable_any) then score = score + 30 end
    if ref.fakeduck and fn.hotkey_active(ref.fakeduck[2]) then score = score + 25 end
    if ref.autopeek[2] and fn.hotkey_active(ref.autopeek[2]) then score = score - 35 end
    if b_band(e_prop(me, "m_fFlags") or 0, CY.FL_GROUND) == 0 then score = score - 20 end
    local tgt = c_threat()
    if tgt and e_alive(tgt) and not e_dormant(tgt) then
        local mx, my = e_origin(me)
        local tx, ty = e_origin(tgt)
        if mx and tx then
            local dx, dy = tx - mx, ty - my
            local d = m_sqrt(dx * dx + dy * dy)
            if d > 1 then
                local nx, ny = dx / d, dy / d
                local vx = e_prop(me, "m_vecVelocity[0]") or 0
                local vy = e_prop(me, "m_vecVelocity[1]") or 0
                local closing = vx * nx + vy * ny
                if closing > 40 then score = score - 25 elseif mg.lp.speedxy < 20 then score = score + 20 end
                local e = ents[tgt]; local pd = e and e.p
                if pd then
                    local tclosing = -((pd.vx or 0) * nx + (pd.vy or 0) * ny)
                    if tclosing > 60 then score = score + 30 end
                    if pd.st == ST.RUSHING then score = score + 20 end
                    if pd.st == ST.STANDING then score = score - 10 end
                end
            end
        end
    else score = score + 15 end
    HS.dt_score = fn.lerp(HS.dt_score, score, 0.25)
    local now = g_realtime()
    local want = HS.dt_score > 0 and "Defensive" or "Offensive"
    if want ~= HS.dt_mode and m_abs(HS.dt_score) > fn.get(m.rage.dt_auto_deadband, 12) and (now - HS.dt_mode_t) > 0.35 then
        HS.dt_mode, HS.dt_mode_t = want, now
    end
    fn.ovr(DT_MODE, HS.dt_mode)
end

function fn.dt_feedback(w, hit, reason)
    if not w or not fn.get(m.rage.dthc_learn) then return end
    local t = HS.dt_learn[w]
    if not t then t = {hits = 0, misses = 0, bias = 0, t = g_realtime()}; HS.dt_learn[w] = t end
    local now = g_realtime()
    local age = now - (t.t or now)
    if age > 0 then t.bias = t.bias * m_max(0, 1 - age * 0.02) end
    t.t = now
    if hit then t.hits = t.hits + 1; t.bias = fn.clamp(t.bias - 1.5, -10, 15)
    else if reason == "spread" or reason == "death" then return end; t.misses = t.misses + 1; t.bias = fn.clamp(t.bias + 2.5, -10, 15) end
end

function fn.hitscale_tick()
    local me = e_local(); if not me or not e_alive(me) then return end
    local w = fn.weapon_type(e_weapon(me))
    if w ~= HS.cur_wtype then fn.rage_invalidate() end
    HS.cur_wtype = w
    local hs_on = fn.get(m.rage.hs)
    if HS.was_hs and not hs_on then fn.rage_restore_one(HS.bk_mp, ref.mpscale); fn.rage_restore_one(HS.bk_hc, ref.hitchance); fn.rage_restore_one(HS.bk_dmg, ref.mindmg); fn.rage_invalidate() end
    HS.was_hs = hs_on
    local dt_on = fn.get(m.rage.dthc) and ref.doubletap[1] and fn.get(ref.doubletap[1])
    if HS.was_dthc and not dt_on then fn.rage_restore_one(HS.bk_dthc, ref.dthc); fn.rage_invalidate() end
    HS.was_dthc = dt_on
    local prof = HS.PROFILE[w] or HS.PROFILE.Global
    local self_air = b_band(e_prop(me, "m_fFlags") or 0, CY.FL_GROUND) == 0
    local dist = 0
    local tgt = c_threat()
    if tgt and e_alive(tgt) then
        local ex, ey, ez = c_eye()
        local e = ents[tgt]; local pd = e and e.p
        local tx, ty, tz
        if pd and pd.prx ~= 0 then tx, ty, tz = pd.prx, pd.pry, pd.prz else tx, ty, tz = e_origin(tgt) end
        if ex and tx then local dx, dy, dz = tx - ex, ty - ey, tz - ez; dist = m_sqrt(dx * dx + dy * dy + dz * dz) end
    end
    -- spread floor runs whether or not adaptive hitscale is on: a shot the cone
    -- decides is a coin flip should be gated either way
    if tgt and e_alive(tgt) then
        local hp = e_prop(tgt, "m_iHealth") or 100
        local lethal = (hp > 0 and hp <= 40) or (prof.dmg ~= nil and prof.dmg >= hp)
        HS.req.hc_floor = fn.spread_floor(dist, mg.lp.speedxy, self_air, prof.sf, lethal)
    end
    fn.adaptive_hitscale(me, w, prof, dist, self_air)
    fn.adaptive_dthc(me, w, prof, dist, self_air)
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Aimtools: DT recharge, jump scout, autopeek fix, custom hitchance, auto HS
-- ═══════════════════════════════════════════════════════════════════════════
function fn.dt_recharge()
    if not fn.get(m.rage.dt_recharge) then return end
    if not (ref.doubletap[2] and fn.hotkey_active(ref.doubletap[2])) then return end
    if fn.tb_charged() then return end
    local d = fn.tb_depth()
    if d < 2 then return end
    fn.hc_penalty(d * 3)
end

local hit_ind = false
function fn.custom_hitchance()
    if not fn.get(m.rage.override_hc) then hit_ind = false; return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local w = e_weapon(lp); if not w then return end
    local wn = e_class(w)
    local is_r8 = wn == "CDEagle" and e_prop(w, "m_iItemDefinitionIndex") == 64
    local wl = fn.get(m.rage.ovr_hc_wep, {})
    if fn.contains(wl, "Scout") and wn == "CWeaponSSG08" and fn.get(m.rage.ovr_scout_hc, 0) > 0 then fn.hc_request(fn.get(m.rage.ovr_scout_hc), 3); hit_ind = true
    elseif fn.contains(wl, "AWP") and wn == "CWeaponAWP" and fn.get(m.rage.ovr_awp_hc, 0) > 0 then fn.hc_request(fn.get(m.rage.ovr_awp_hc), 3); hit_ind = true
    elseif fn.contains(wl, "Auto") and (wn == "CWeaponSCAR20" or wn == "CWeaponG3SG1") and fn.get(m.rage.ovr_auto_hc, 0) > 0 then fn.hc_request(fn.get(m.rage.ovr_auto_hc), 3); hit_ind = true
    elseif fn.contains(wl, "R8") and is_r8 and fn.get(m.rage.ovr_r8_hc, 0) > 0 then fn.hc_request(fn.get(m.rage.ovr_r8_hc), 3); hit_ind = true
    else hit_ind = false end
end

function fn.jump_scout(cmd)
    if mg.jumpscout then mg.jumpscout = false; cmd.in_speed = 0; fn.hc_request(fn.get(m.rage.scout_hc, 75), 2) end
    if mg.lp.speedxy < 30 and mg.airtime < 30 and cmd.in_forward == 0 and cmd.in_back == 0 and cmd.in_left == 0 and cmd.in_right == 0 then
        fn.ovr(ref.autostrafe, false)
    end
    if not fn.get(m.rage.jump_scout) then return end
    local sz = mg.lp.speedz
    if sz ~= 0 and sz < 50 and sz > -10 and mg.weaponname == "CWeaponSSG08" and mg.shottimer <= 0 then
        if e_prop(mg.lp.id, "m_bDucked") == 0 then cmd.in_speed = 1 end
        mg.jumpscout = true
        fn.hc_request(fn.get(m.rage.jump_hc, 40), 2)
    end
end

function fn.fix_autopeek(cmd)
    if not fn.get(m.rage.fix_autopeek) then return end
    if ref.autopeek[2] and fn.hotkey_active(ref.autopeek[2]) then
        mg.autopeekfix = mg.autopeekfix - 1
        if mg.autopeekfix > 0 then cmd.sidemove = 0; cmd.forwardmove = 0 end
    else mg.autopeekfix = 0 end
end

function fn.auto_hideshots(cmd)
    if not fn.get(m.rage.auto_hs) then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local w = e_weapon(lp); if not w then return end
    local wn = e_class(w)
    local wl = fn.get(m.rage.auto_hs_wep, {})
    local blocked = (wn == "CWeaponSSG08" and fn.contains(wl, "Scout")) or (wn == "CWeaponAWP" and fn.contains(wl, "AWP"))
        or ((wn == "CWeaponSCAR20" or wn == "CWeaponG3SG1") and fn.contains(wl, "Auto")) or (wn == "CDEagle" and fn.contains(wl, "Deagle & R8"))
        or wn == "CWeaponTaser" or wn == "CKnife"
    if blocked then return end
    local ps = fn.player_state(cmd)
    local sl_ = fn.get(m.rage.auto_hs_state, {})
    local allowed = (fn.contains(sl_, "Standing") and ps == "Standing") or (fn.contains(sl_, "Walking") and ps == "Walking")
        or (fn.contains(sl_, "Crouching") and ps == "Ducking") or (fn.contains(sl_, "Sneaking") and ps == "Sneaking")
    if allowed and ref.hideshots[1] then
        fn.ovr(ref.hideshots[1], true)
        if ref.doubletap[1] then fn.ovr(ref.doubletap[1], false) end
    end
end

function fn.hideshot_fix()
    if not fn.get(m.rage.hideshot_fix) then return end
    if ref.hideshots[1] and fn.get(ref.hideshots[1]) and ref.hideshots[2] and fn.hotkey_active(ref.hideshots[2]) then
        for _, v in ipairs(ref.FL.enabled) do fn.ovr(v, false) end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Break animations (all 19)
-- ═══════════════════════════════════════════════════════════════════════════
local tweak_air = false
function fn.set_lean(me, w)
    if entity_lib then
        local ok, ent = pcall(entity_lib.new, me)
        if ok and ent then local ov = ent:get_anim_overlay(12); if ov then ov.weight = w; return true end end
    end
    local l = fn.layerbase(me, 12)
    if l then return pcall(fn.ALFS, l, AL.WEIGHT, w) end
    return false
end

function fn.break_anims()
    if not fn.get(m.aa.tweak_aa) then return end
    local me = e_local(); if not me or not e_alive(me) then return end
    local o = fn.get(m.aa.tweak_opts, {})
    local def = fn.in_defensive()
    local boost = def and fn.contains(o, "Defensive boost")
    local mul = boost and (fn.get(m.aa.tweak_defmul, 250) * 0.01) or 1
    local own = fn.pose_body(me)
    if own then mg.own_desync = own > 0 and m_ceil(own) or m_floor(own) end
    local ast = fn.animbase(me)
    if ast then local md = fn.max_desync(ast); if md then mg.own_max = md end end
    local vx = e_prop(me, "m_vecVelocity[0]") or 0
    local vy = e_prop(me, "m_vecVelocity[1]") or 0
    local speed = m_sqrt(vx * vx + vy * vy)
    local grounded = b_band(e_prop(me, "m_fFlags") or 0, CY.FL_GROUND) ~= 0
    local sp = entity.set_prop

    if fn.contains(o, "Extreme body lean") and speed >= 3 then
        local w = (fn.get(m.aa.tweak_lean, 100) * 0.01) * mul
        if fn.contains(o, "Speed scaled lean") then w = w * (1 + fn.clamp(speed / 250, 0, 1) * 0.8) end
        if fn.contains(o, "Lean jitter") then w = w * ((g_tick() % 4) < 2 and 1 or -0.6) end
        if fn.contains(o, "Freestand lean") and mg.fsside ~= nil then w = w * (mg.fsside and 1 or -1) end
        if fn.contains(o, "On-shot spike") and mg.shottimer > 7 then w = w * 3 end
        local hp = mg.head_peek or 0
        if hp ~= 0 then local hw = fn.get(m.aa.head_peek_lean, 100) * 0.01; if hw > 0 then w = m_abs(w) * hp * m_max(hw, 1) end end
        fn.set_lean(me, w)
    end
    if fn.contains(o, "Air walk") and speed > 1.5 then local l6 = fn.layerbase(me, 6); if l6 then pcall(fn.ALFS, l6, AL.WEIGHT, 1) end end
    if fn.contains(o, "Earthquake") then local l12 = fn.layerbase(me, 12); if l12 then pcall(fn.ALFS, l12, AL.WEIGHT, client.random_float(0, 1)) end end
    if fn.contains(o, "Fake walk") then local l12, l6 = fn.layerbase(me, 12), fn.layerbase(me, 6); if l12 then pcall(fn.ALFS, l12, AL.WEIGHT, 0) end; if l6 then pcall(fn.ALFS, l6, AL.WEIGHT, 0) end end
    if fn.contains(o, "Fake flash") then local l9 = fn.layerbase(me, 9); if l9 then pcall(fn.ALIS, l9, AL.SEQUENCE, 224); pcall(fn.ALFS, l9, AL.WEIGHT, 1) end end
    if fn.contains(o, "Moonwalk") then sp(me, "m_flPoseParameter", 0, PZ.MOVE_YAW) end
    if fn.contains(o, "Smoothing") then sp(me, "m_flPoseParameter", 0, PZ.LEAN_YAW) end
    if fn.contains(o, "Fallen legs") then sp(me, "m_flPoseParameter", 1, PZ.JUMP_FALL) end
    if fn.contains(o, "Slide") then sp(me, "m_flPoseParameter", 1, PZ.STRAFE_YAW) end
    if fn.contains(o, "Fake duck") then sp(me, "m_flPoseParameter", 1, PZ.STAND) end
    if fn.contains(o, "Break legs") then
        sp(me, "m_flPoseParameter", 0, PZ.BLEND_WALK); sp(me, "m_flPoseParameter", 0, PZ.BLEND_RUN); sp(me, "m_flPoseParameter", 0, PZ.BLEND_CROUCH)
        if boost then sp(me, "m_flPoseParameter", 0, PZ.LADDER_YAW) end
    end
    if fn.contains(o, "Break move yaw") then local ph = (g_tick() % 2 == 0) and 0 or 1; sp(me, "m_flPoseParameter", ph, PZ.STRAFE_YAW); sp(me, "m_flPoseParameter", 1 - ph, PZ.MOVE_YAW) end
    if fn.contains(o, "Air desync") and not grounded then sp(me, "m_flPoseParameter", 0.5, PZ.JUMP_FALL); tweak_air = true end
    if fn.contains(o, "Land pitch break") then
        local landed = false
        if ast then local ok, v = pcall(function() return fn.ASB(ast, AS.HIT_GROUND) and fn.ASF(ast, AS.HEAD_HEIGHT) > 0.101 and fn.ASB(ast, AS.ON_GROUND) end); landed = ok and v or false end
        if not landed then landed = tweak_air and grounded end
        if landed and grounded then sp(me, "m_flPoseParameter", 0.5, PZ.BODY_PITCH) end
    end
    if grounded then tweak_air = false end
end

function fn.head_peek_lean()
    local hp = mg.head_peek or 0
    if hp == 0 then return end
    local w = fn.get(m.aa.head_peek_lean, 100) * 0.01
    if w <= 0 then return end
    if fn.get(m.aa.tweak_aa) and fn.contains(fn.get(m.aa.tweak_opts, {}), "Extreme body lean") and mg.lp.speedxy >= 3 then return end
    local me = e_local(); if not me or not e_alive(me) then return end
    fn.set_lean(me, w * hp)
end

local is_on_ground = false
function fn.anim_breakers_poly()
    if not fn.get(m.vis.anim_breaker) then return end
    if not entity_lib then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local xv = e_prop(lp, "m_vecVelocity[0]") or 0
    local move = m_abs(xv) > 5
    local ok, ent = pcall(entity_lib.new, lp)
    if not ok or not ent then return end
    if is_on_ground then
        local land = fn.get(m.vis.anim_land)
        if land == "Static" then entity.set_prop(lp, "m_flPoseParameter", 1, 0); fn.ovr(ref.leg, "Always slide")
        elseif land == "Walking" then fn.ovr(ref.leg, "Never slide")
        elseif land == "Fipp" and move then entity.set_prop(lp, "m_flPoseParameter", 1, 7); fn.ovr(ref.leg, "Never slide") end
    end
    local air = fn.get(m.vis.anim_air)
    if air == "Static" then entity.set_prop(lp, "m_flPoseParameter", 1, 6) end
    if air == "Fipp" and not is_on_ground then local ov = ent:get_anim_overlay(6); if ov then ov.weight = 1 end end
    local add = fn.get(m.vis.anim_additions, {})
    if fn.contains(add, "Pitch 0 on Land") and is_on_ground then
        local as = fn.animbase(lp)
        if as and pcall(function() return fn.ASB(as, AS.HIT_GROUND) end) and fn.ASB(as, AS.HIT_GROUND) then entity.set_prop(lp, "m_flPoseParameter", 0.5, 12) end
    end
    if fn.contains(add, "Move Lean") and not is_on_ground then local ov = ent:get_anim_overlay(12); if ov then ov.weight = 1 end end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Utils: viewmodel, aspect, thirdperson, fast ladder, console, clantag
-- ═══════════════════════════════════════════════════════════════════════════
function fn.apply_view()
    if fn.get(m.utils.thirdperson) then cvar.cam_idealdist:set_int(fn.get(m.utils.thirdperson_dist, 150)) else cvar.cam_idealdist:set_int(150) end
    if fn.get(m.utils.aspect) then cvar.r_aspectratio:set_float(fn.get(m.utils.aspect_value, 0) * 0.01) else cvar.r_aspectratio:set_float(0) end
    if fn.get(m.utils.vm_changer) then
        local lp = e_local(); if not lp or not e_alive(lp) then return end
        cvar.viewmodel_fov:set_raw_float(fn.get(m.utils.vm_fov, 68))
        cvar.viewmodel_offset_x:set_raw_float(fn.get(m.utils.vm_x, 2))
        cvar.viewmodel_offset_y:set_raw_float(fn.get(m.utils.vm_y, 0))
        cvar.viewmodel_offset_z:set_raw_float(fn.get(m.utils.vm_z, -1))
        local w = e_weapon(lp); local is_knife = w and e_class(w) == "CKnife"
        local base = fn.get(m.utils.vm_opposite) and 0 or 1
        if fn.get(m.utils.vm_opposite_knife) and is_knife then base = 1 - base end
        cvar.cl_righthand:set_int(base)
    end
end

function fn.fast_ladder(cmd)
    local lp = e_local()
    if not lp or not fn.get(m.utils.fast_ladder) or e_prop(lp, "m_MoveType") ~= 9 then return end
    if cmd.forwardmove > 0 and cmd.pitch < 45 then
        cmd.pitch = 89; cmd.in_moveright = 1; cmd.in_moveleft = 0; cmd.in_forward = 0; cmd.in_back = 1
        if cmd.sidemove == 0 then cmd.yaw = cmd.yaw + 90 elseif cmd.sidemove < 0 then cmd.yaw = cmd.yaw + 150 else cmd.yaw = cmd.yaw + 30 end
    elseif cmd.forwardmove < 0 then
        cmd.pitch = 89; cmd.in_moveleft = 1; cmd.in_moveright = 0; cmd.in_forward = 1; cmd.in_back = 0
        if cmd.sidemove == 0 then cmd.yaw = cmd.yaw + 90 elseif cmd.sidemove > 0 then cmd.yaw = cmd.yaw + 150 else cmd.yaw = cmd.yaw + 30 end
    end
end

local console_state = nil
function fn.console_filter(on)
    if console_state == on then return end
    console_state = on
    cvar.developer:set_int(0)
    cvar.con_filter_enable:set_int(on and 1 or 0)
    cvar.con_filter_text:set_string(on and "IrWL5106TZZKNFPz4P4Gl3pSN" or "")
    client.exec(on and "con_filter_enable 1" or "con_filter_enable 0")
end

local ct_frames = {" ", "c", "co", "coc", "coco", "cocoy", "cocoya", "cocoyaw", "cocoyaw", "cocoyaw", "cocoyaw", "cocoyaw", "cocoya", "cocoy", "coco", "coc", "co", "c", " ", " "}
local CT_N, ct_last = #ct_frames, ""
function fn.update_clantag()
    if not fn.get(m.utils.clantag) then if ct_last ~= "" then client.set_clan_tag(""); ct_last = "" end; return end
    local lat = c_latency()
    if lat == nil then return end
    local idx = m_floor(m_fmod((g_tick() + (lat / TICK_IV)) / 22, CT_N) + 1)
    local tag = ct_frames[idx] or " "
    if tag ~= ct_last then client.set_clan_tag(tag); ct_last = tag end
    if ref.clantag then fn.ovr(ref.clantag, false) end
end

local ru_trashtalk = {"cocoyaw on top", "ez", "?", "get good", "nice config bro", "unlucky", "gg"}

-- ═══════════════════════════════════════════════════════════════════════════
--  Telemetry
-- ═══════════════════════════════════════════════════════════════════════════
local hb_names = {[0] = "generic", "head", "chest", "stomach", "left arm", "right arm", "left leg", "right leg", "neck", "?", "gear"}
local shots = {}
local MS = {total = 0, reason = {}, state = {}, stage = {}, weapon = {}, hitbox = {}, jit = {}, src = {},
            sway = 0, def = 0, air = 0, onshot = 0, no_anim = 0, no_direct = 0, high_choke = 0, tele = 0, uncharged = 0}
function fn.inc(t, k) k = k or "?"; t[k] = (t[k] or 0) + 1 end

function fn.snapshot(ent)
    local s, e = {}, ents[ent]
    if not e then return s end
    local v, p, pr, h = e.v, e.p, e.pr, e.h
    if v then s.r_yaw = v.y; s.r_off = v.o; s.r_side = v.s; s.r_bidx = v.bi; s.r_mag = v.mag; s.r_src = v.src; s.r_def = v.d; s.r_sway = v.sw; s.r_onshot = v.onshot; s.r_skipped = v.skipped end
    if pr then s.r_resolved = pr.r; s.r_stage = pr.s end
    if h then s.r_conf = h.cf end
    if p then s.p_state = p.st; s.p_desync = p.ds; s.p_eye = p.aw; s.p_gf = p.gf; s.p_anim = p.hasanim; s.p_pbodyok = p.pbody_ok; s.p_choke = p.chk; s.p_jit = p.jit; s.p_pitch = p.ap; s.p_tele = p.tele; s.p_maxds = p.maxdes; s.p_sscore = p.sscore and p.sscore[p.st] or 0 end
    return s
end

function fn.miss_stats(reason, s)
    MS.total = MS.total + 1
    fn.inc(MS.reason, reason or "?"); fn.inc(MS.state, s.p_state and CY.SNAME[s.p_state] or "?")
    fn.inc(MS.stage, s.r_bidx or 0); fn.inc(MS.jit, s.p_jit or "?"); fn.inc(MS.src, s.r_src or "?")
    if s.r_sway then MS.sway = MS.sway + 1 end
    if s.r_def then MS.def = MS.def + 1 end
    if s.r_onshot then MS.onshot = MS.onshot + 1 end
    if s.p_state == ST.AIR or s.p_state == ST.AIR_CROUCH then MS.air = MS.air + 1 end
    if not s.p_anim then MS.no_anim = MS.no_anim + 1 end
    if not (s.p_anim or s.p_pbodyok) then MS.no_direct = MS.no_direct + 1 end
    if (s.p_choke or 0) >= 6 then MS.high_choke = MS.high_choke + 1 end
    if s.p_tele then MS.tele = MS.tele + 1 end
end

function fn.dump_stats()
    client.color_log(255, 255, 255, s_format("[CY-STATS] %d misses this session", MS.total))
    if MS.total == 0 then return end
    local function line(label, t)
        local p = {}
        for k, v in pairs(t) do p[#p + 1] = s_format("%s=%d", tostring(k), v) end
        client.color_log(180, 220, 255, s_format("  %s: %s", label, t_concat(p, "  ")))
    end
    line("reason", MS.reason); line("state", MS.state); line("stage", MS.stage); line("jitter", MS.jit); line("source", MS.src)
    client.color_log(255, 200, 120, s_format("  flags: sway=%d def=%d onshot=%d air=%d no_anim=%d no_direct=%d choke=%d tele=%d", MS.sway, MS.def, MS.onshot, MS.air, MS.no_anim, MS.no_direct, MS.high_choke, MS.tele))
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Visuals
-- ═══════════════════════════════════════════════════════════════════════════
local scr_w, scr_h = client.screen_size()
local sx, sy = scr_w / 2, scr_h / 2
local scoped_space, scoped_space_man = 0, 0

function fn.text_fade(x, y, speed, c1, c2, text, flag)
    local final, ct = "", g_curtime()
    for i = 1, #text do
        local wave = m_cos(8 * speed * ct + (i * 10) / 30)
        local t = fn.clamp(wave, 0, 1)
        final = final .. "\a" .. fn.rgba_hex(fn.lerp(c1.r, c2.r, t), fn.lerp(c1.g, c2.g, t), fn.lerp(c1.b, c2.b, t), c1.a) .. s_sub(text, i, i)
    end
    renderer.text(x, y, c1.r, c1.g, c1.b, c1.a, flag, nil, final)
end

function fn.draw_indicators()
    if not fn.get(m.vis.indicators) then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local ir, ig, ib = fn.get(m.vis.ind_color)
    ir, ig, ib = ir or 250, ig or 200, ib or 140
    local emp = 20
    local scpd = e_prop(lp, "m_bIsScoped") == 1
    scoped_space = fn.approach(scoped_space, scpd and 30 or 0, 20)
    local pose = (e_prop(lp, "m_flPoseParameter", 11) or 0.5) * 120 - 60
    local ds = pose > 0 and "R" or "L"
    local el = fn.get(m.vis.ind_elements, {})
    if fn.contains(el, "Branch") then renderer.text(sx + scoped_space, sy + emp, 255, 255, 255, 255, "c-", 0, s_upper(build)); emp = emp + 9 end
    if fn.get(m.vis.ind_gradient) then
        fn.text_fade(sx + scoped_space, sy + emp, -0.5, {r = 100, g = 100, b = 100, a = 255}, {r = ir, g = ig, b = ib, a = 255}, s_upper(lua_name), "c-")
    else renderer.text(sx + scoped_space, sy + emp, ir, ig, ib, 255, "c-", 0, s_upper(lua_name)) end
    emp = emp + 9
    if fn.contains(el, "State") then renderer.text(sx + scoped_space, sy + emp, 255, 255, 255, 255, "c-", 0, s_upper(mg.indefensive and "DEFENSIVE" or mg.state)); emp = emp + 9 end
    if fn.contains(el, "Desync Side") then renderer.text(sx + scoped_space, sy + emp, 255, 255, 255, 255, "c-", 0, "SIDE: \a" .. fn.rgba_hex(ir, ig, ib, 255) .. ds); emp = emp + 9 end
    if fn.contains(el, "Hotkeys") then
        if ref.forcebaim and fn.get(ref.forcebaim) then renderer.text(sx + scoped_space, sy + emp, 255, 100, 100, 255, "c-", 0, "BAIM"); emp = emp + 9 end
        if ref.safepoint and fn.get(ref.safepoint) then renderer.text(sx + scoped_space, sy + emp, 255, 100, 100, 255, "c-", 0, "SAFE"); emp = emp + 9 end
        if ref.doubletap[1] and fn.get(ref.doubletap[1]) and ref.doubletap[2] and fn.hotkey_active(ref.doubletap[2]) then
            local ch = fn.dt_charged() and fn.tb_charged()
            local dtxt = "DT"
            if DT_MODE and fn.get(m.rage.dt_auto) then dtxt = HS.dt_mode == "Defensive" and "DT-D" or "DT-O" end
            renderer.text(sx + scoped_space, sy + emp, 255, ch and 255 or 0, ch and 255 or 0, 255, "c-", 0, dtxt); emp = emp + 9
        elseif ref.hideshots[2] and fn.hotkey_active(ref.hideshots[2]) then renderer.text(sx + scoped_space, sy + emp, 255, 255, 255, 255, "c-", 0, "OSAA"); emp = emp + 9 end
        if ref.autopeek[2] and fn.hotkey_active(ref.autopeek[2]) then renderer.text(sx + scoped_space, sy + emp, 255, 255, 255, 255, "c-", 0, "PEEK"); emp = emp + 9 end
        if mg.lc_broken then renderer.text(sx + scoped_space, sy + emp, 255, 150, 60, 255, "c-", 0, "LC"); emp = emp + 9 end
        if mg.head_peek ~= 0 then renderer.text(sx + scoped_space, sy + emp, 180, 120, 255, 255, "c-", 0, mg.head_peek > 0 and "HEAD >" or "< HEAD"); emp = emp + 9 end
    end
end

function fn.draw_arrows()
    if not fn.get(m.vis.arrows) then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local vx, vy = e_prop(lp, "m_vecVelocity"); vx, vy = vx or 0, vy or 0
    local scpd = e_prop(lp, "m_bIsScoped") == 1
    scoped_space_man = fn.approach(scoped_space_man, scpd and 15 or 0, 20)
    local mr, mg_, mb = fn.get(m.vis.ind_color)
    mr, mg_, mb = mr or 250, mg_ or 200, mb or 140
    local vo = fn.get(m.vis.arrows_velocity) and m_sqrt(vx * vx + vy * vy) / 7 or 0
    local tp = fn.get(m.vis.arrows_type, "Modern")
    local lc, rc = yaw_direction == -90, yaw_direction == 90
    if tp == "TeamSkeet" then
        local pose = (e_prop(lp, "m_flPoseParameter", 11) or 0.5) * 120 - 60
        renderer.triangle(sx - 55 - vo, sy - scoped_space_man, sx - 42 - vo, sy - 9 - scoped_space_man, sx - 42 - vo, sy + 9 - scoped_space_man, lc and mr or 35, lc and mg_ or 35, lc and mb or 35, lc and 255 or 150)
        renderer.triangle(sx + 55 + vo, sy - scoped_space_man, sx + 42 + vo, sy - 9 - scoped_space_man, sx + 42 + vo, sy + 9 - scoped_space_man, rc and mr or 35, rc and mg_ or 35, rc and mb or 35, rc and 255 or 150)
        renderer.rectangle(sx - 40 - vo, sy - 9 - scoped_space_man, 2, 18, pose <= 0 and mr or 35, pose <= 0 and mg_ or 35, pose <= 0 and mb or 35, pose <= 0 and 255 or 150)
        renderer.rectangle(sx + 38 + vo, sy - 9 - scoped_space_man, 2, 18, pose > 0 and mr or 35, pose > 0 and mg_ or 35, pose > 0 and mb or 35, pose > 0 and 255 or 150)
    elseif tp == "Old School" then
        renderer.text(sx + 60 + vo, sy - scoped_space_man, rc and mr or 35, rc and mg_ or 35, rc and mb or 35, rc and 255 or 50, "c+", 0, ">")
        renderer.text(sx - 60 - vo, sy - scoped_space_man, lc and mr or 35, lc and mg_ or 35, lc and mb or 35, lc and 255 or 50, "c+", 0, "<")
    else
        renderer.text(sx + 60 + vo, sy - scoped_space_man, rc and mr or 35, rc and mg_ or 35, rc and mb or 35, rc and 255 or 50, "c+", 0, "\xE2\x9D\xB1")
        renderer.text(sx - 60 - vo, sy - scoped_space_man, lc and mr or 35, lc and mg_ or 35, lc and mb or 35, lc and 255 or 50, "c+", 0, "\xE2\x9D\xB0")
    end
end

function fn.draw_damage()
    if not fn.get(m.vis.damage) then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local on = ref.mindmg_override[2] and fn.hotkey_active(ref.mindmg_override[2])
    local raw = fn.get(ref.mindmg) or 0
    local txt = raw > 100 and ("+" .. (raw - 100)) or (raw < 1 and "auto" or tostring(raw))
    renderer.text(sx + 10, sy - 10, 255, 255, 255, on and 255 or 100, "c-", 0, txt)
end

function fn.rounded_rect(x, y, w, h, r, g, b, a, radius)
    y = y + radius
    for _, d in ipairs({{x + radius, y, 180}, {x + w - radius, y, 90}, {x + radius, y + h - radius * 2 + 1, 270}, {x + w - radius, y + h - radius * 2 + 1, 0}}) do
        renderer.circle(d[1], d[2], r, g, b, a, radius, d[3], 0.25)
    end
    for _, d in ipairs({{x + radius, y, w - radius * 2, h - radius * 2 + 1}, {x + radius, y - radius, w - radius * 2, radius - 1}, {x + radius, y + h - radius * 2, w - radius * 2, radius + 1}}) do
        renderer.rectangle(d[1], d[2], d[3], d[4], r, g, b, a)
    end
end

function fn.draw_velocity_warning()
    if not fn.get(m.vis.velocity_warning) then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local alpha = m_floor(m_sin((g_realtime() % 3) * 4) * 89 + 90)
    local vel = (e_prop(lp, "m_flVelocityModifier") or 1) * 100
    if vel < 100 or ui.is_menu_open() then
        renderer.text(sx, sy - 360, 255, 2.55 * vel, 2.55 * vel, alpha, "c", 0, "~ velocity ~")
        fn.rounded_rect(sx - 50, sy - 350, 100, 5, 25, 25, 25, 150, 3)
        fn.rounded_rect(sx - 49, sy - 349, m_max(vel - 2, 0), 3, 250, 200, 140, 255, 2)
    end
end

function fn.draw_defensive()
    if not fn.get(m.vis.defensive_ind) then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local alpha = m_floor(m_sin((g_realtime() % 3) * 4) * 89 + 90)
    local norm_ = m_floor(fn.tb_depth() * 7.6)
    if norm_ > 0 then
        renderer.text(sx, sy - 310, 255, 255, 255, 2.55 * norm_, "c", 0, "~ safe ~")
        fn.rounded_rect(sx - 50, sy - 300, 100, 5, 25, 25, 25, 150, 3)
        fn.rounded_rect(sx - 49, sy - 299, norm_, 3, 250, 200, 140, 255, 2)
    elseif ui.is_menu_open() then
        renderer.text(sx, sy - 310, 255, 255, 255, alpha, "c", 0, "~ safe ~")
        fn.rounded_rect(sx - 50, sy - 300, 100, 5, 25, 25, 25, 150, 3)
        fn.rounded_rect(sx - 49, sy - 299, 98, 3, 250, 200, 140, 255, 2)
    end
end

function fn.draw_custom_inds()
    if not fn.get(m.vis.custom_inds) then return end
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local el = fn.get(m.vis.custom_inds_elements, {})
    local ir, ig, ib = 250, 200, 140
    if fn.contains(el, "Min.Damage") and ref.mindmg_override[2] and fn.hotkey_active(ref.mindmg_override[2]) then renderer.indicator(ir, ig, ib, 255, "DMG: ", fn.get(ref.mindmg) or 0) end
    if fn.contains(el, "Force baim") and ref.forcebaim and fn.get(ref.forcebaim) then renderer.indicator(ir, ig, ib, 255, "BAIM") end
    if fn.contains(el, "Force safe point") and ref.safepoint and fn.get(ref.safepoint) then renderer.indicator(ir, ig, ib, 255, "SAFE") end
    if fn.contains(el, "Fake Duck") and ref.fakeduck and fn.hotkey_active(ref.fakeduck[2]) then renderer.indicator(ir, ig, ib, 255, "DUCK") end
    if fn.contains(el, "Double tap") and ref.doubletap[1] and fn.get(ref.doubletap[1]) and ref.doubletap[2] and fn.hotkey_active(ref.doubletap[2]) then
        local dlabel = DT_MODE and fn.get(m.rage.dt_auto) and (HS.dt_mode == "Defensive" and "DT-D" or "DT-O") or "DT"
        if fn.dt_charged() and fn.tb_charged() then renderer.indicator(ir, ig, ib, 255, dlabel) else renderer.indicator(255, 0, 0, 255, dlabel) end
    elseif fn.contains(el, "Hide-Shots") and ref.hideshots[2] and fn.hotkey_active(ref.hideshots[2]) then renderer.indicator(ir, ig, ib, 255, "HS") end
    if fn.contains(el, "Ping spike") and ref.ping_spike[1] and fn.get(ref.ping_spike[1]) and ref.ping_spike[2] and fn.hotkey_active(ref.ping_spike[2]) then renderer.indicator(ir, ig, ib, 255, "PING") end
    if fn.contains(el, "Freestanding") and ref.AA.freestand[1] and fn.get(ref.AA.freestand[1]) then renderer.indicator(ir, ig, ib, 255, "FS") end
    if fn.contains(el, "Hitchance Override") and hit_ind then renderer.indicator(ir, ig, ib, 255, "HC") end
end

function fn.draw_watermark()
    if not fn.get(m.vis.watermark) then return end
    local wt = fn.get(m.vis.watermark_type, "Modern")
    if wt == "Modern" then
        local c1r, c1g, c1b = fn.get(m.vis.watermark_color)
        c1r, c1g, c1b = c1r or 250, c1g or 200, c1b or 140
        local pos = fn.get(m.vis.watermark_pos, "Bottom")
        local wx = pos == "Left" and sx - sx / 1.05 or (pos == "Right" and sx + sx / 1.05 or sx)
        local wy = pos == "Bottom" and sy + sy / 1.05 or sy
        fn.text_fade(wx, wy, -0.2, {r = 50, g = 50, b = 50, a = 255}, {r = c1r, g = c1g, b = c1b, a = 255}, "C O C O Y A W", "c")
    elseif wt == "Minimalistic" then
        local alpha = m_floor(m_sin((g_realtime() % 3) * 4) * 89 + 90)
        local pos = fn.get(m.vis.watermark_pos, "Bottom")
        local wx = pos == "Left" and sx - sx / 1.07 or (pos == "Right" and sx + sx / 1.07 or sx)
        local wy = pos == "Bottom" and sy + sy / 1.05 or sy
        renderer.text(wx, wy, 255, 255, 255, alpha, "c", 0, "cocoyaw ~ " .. build)
    else
        local lat = m_floor((c_latency() or 0) * 1000 + 0.5)
        local tr = m_floor(TICK_INV)
        local h_, min_, s_ = client.system_time()
        local text = s_format("cocoyaw | %dms | %dtick | %02d:%02d:%02d", lat, tr, h_, min_, s_)
        local mw, mh = renderer.measure_text("", text)
        renderer.rectangle(scr_w - mw - 22, 14, mw + 8, mh + 8, 240, 110, 140, 130)
        renderer.text(scr_w - mw - 18, 18, 240, 160, 180, 250, "", 0, text)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
--  Callbacks
-- ═══════════════════════════════════════════════════════════════════════════
local chance_of_hit, history_ticks = 0, 0
local missdump_held = false

client.set_event_callback("round_start", function() round_ended = false end)
client.set_event_callback("round_end", function() round_ended = true end)

client.set_event_callback("run_command", function(cmd)
    mg.tb.cmd = cmd.command_number
    fn.baim_update()
    local held = fn.get(m.utils.miss_dump)
    if held and not missdump_held then fn.dump_stats() end
    missdump_held = held
end)

client.set_event_callback("predict_command", function(cmd)
    if cmd.command_number ~= mg.tb.cmd then return end
    mg.tb.cmd = nil
    local me = e_local(); if not me then return end
    local tb = e_prop(me, "m_nTickBase")
    if type(tb) ~= "number" then return end
    if mg.tb.max ~= nil and tb < mg.tb.max - 32 then mg.tb.max = tb; mg.tb.diff = 0; return end
    if mg.tb.max ~= nil then mg.tb.diff = tb - mg.tb.max end
    mg.tb.max = m_max(tb, mg.tb.max or 0)
end)

client.set_event_callback("setup_command", function(cmd)
    fn.restore()
    fn.rage_reset()
    local me = e_local(); mg.lp.id = me; if not me then return end
    mg.threat = c_threat()
    local vx, vy, vz = e_prop(me, "m_vecVelocity")
    vx, vy, vz = vx or 0, vy or 0, vz or 0
    mg.lp.speedxy, mg.lp.speedz = m_sqrt(vx * vx + vy * vy), vz
    mg.lp.duck = e_prop(me, "m_bDucked") == 1
    mg.lp.tickbase = e_prop(me, "m_nTickBase")
    mg.currentloc = vector(e_origin(me)); mg.lp.origin = mg.currentloc
    if mg.shottimer > 0 then mg.shottimer = mg.shottimer - 1 end
    local w = e_weapon(me); local wn = e_class(w)
    mg.weaponswitch = wn ~= mg.weaponname; mg.weaponid = w; mg.weaponname = wn
    if mg.weaponswitch then fn.rage_invalidate() end
    if cmd.chokedcommands == 0 then mg.fl_phase = (mg.fl_phase + 1) % 6 end
    mg.hittable_any = false
    for _, en in ipairs(e_players(true)) do local e = ents[en]; if e and e.p and e.p.hittable then mg.hittable_any = true; break end end

    mg.exploit = ""
    if ref.hideshots[2] and fn.hotkey_active(ref.hideshots[2]) then mg.exploit = "HS" end
    if ref.doubletap[2] and fn.hotkey_active(ref.doubletap[2]) then mg.exploit = "DT" end

    fn.run_direction()
    fn.setup_aa(cmd)
    fn.auto_hideshots(cmd)
    fn.hideshot_fix()
    fn.fix_autopeek(cmd)
    fn.jump_scout(cmd)
    fn.fast_ladder(cmd)
    fn.dt_recharge()
    fn.custom_hitchance()
    fn.dt_auto()
    -- every hitchance/mp/dmg/dthc producer has filed by now; one writer resolves
    -- them against the weapon actually in our hands
    fn.hitscale_tick()
    if fn.get(m.vis.custom_inds) and ref.feature_inds then fn.ovr(ref.feature_inds, "") end
    fn.rage_flush()

    is_on_ground = cmd.in_jump == 0
    mg.airtime = mg.lp.speedz ~= 0 and m_min(mg.airtime + 1, 100) or 0
    mg.groundtimer = mg.lp.speedz == 0 and m_min(mg.groundtimer + 1, 100) or 0
    mg.shotbool = false
end)

client.set_event_callback("net_update_end", function()
    if not fn.get(m.rage.resolver, true) then return end
    local en = e_players(true)
    if fn.is_autosniper(mg.weaponname) then fn.backtrack_record(en) end
    for i = 1, #en do fn.resolve(en[i]) end
end)

client.set_event_callback("pre_render", function()
    fn.break_anims()
    fn.head_peek_lean()
    fn.anim_breakers_poly()
end)

client.set_event_callback("paint", function()
    fn.draw_indicators(); fn.draw_arrows(); fn.draw_damage(); fn.draw_velocity_warning(); fn.draw_defensive(); fn.draw_custom_inds(); fn.draw_watermark()
    fn.apply_view()
    fn.update_clantag()
end)

client.set_event_callback("paint_ui", function()
    if ui.is_menu_open() then fn.menu_hide_builtin(false) end
end)

client.set_event_callback("aim_fire", function(s)
    local r = {target = s.target, name = entity.get_player_name(s.target), bt = s.backtrack, dmg = s.damage,
               aimed = hb_names[s.hitgroup] or "?", tp = s.teleported, tick = s.tick,
               dt = ref.doubletap[1] and fn.get(ref.doubletap[1]) and ref.doubletap[2] and fn.hotkey_active(ref.doubletap[2]) or false, wtype = HS.cur_wtype}
    chance_of_hit = m_floor(s.hit_chance or 0)
    history_ticks = g_tick() - (s.tick or g_tick())
    if fn.get(m.utils.miss_logs) and s.target then
        r.snap = fn.snapshot(s.target); r.weapon = mg.weaponname
        local me = e_local(); local ex, ey, ez = c_eye(); local tx, ty, tz = e_origin(s.target)
        if ex and tx then local dx, dy, dz = tx - ex, ty - ey, tz - ez; r.dist = m_sqrt(dx * dx + dy * dy + dz * dz) end
    end
    shots[s.id] = r
    if ref.autopeek[2] and fn.hotkey_active(ref.autopeek[2]) then mg.autopeekfix = 30 end
    mg.shottimer = 10; mg.shotbool = true
    if fn.get(m.rage.resolver, true) and fn.is_autosniper(mg.weaponname) and s.target then fn.backtrack_apply(s.target, fn.backtrack_best(s.target)) end
end)

client.set_event_callback("aim_hit", function(s)
    local r = shots[s.id]
    if r and fn.get(m.utils.logs) and fn.contains(fn.get(m.utils.log_types, {}), "Hit") then
        fn.log_segments({{fn.color(0, 255, 0), "Hit "}, {fn.color(250, 200, 140), entity.get_player_name(s.target)}, {fn.color(200, 200, 200), "'s " .. (hb_names[s.hitgroup] or "?") .. " for " .. s.damage .. " (bt: " .. history_ticks .. ") (hc: " .. chance_of_hit .. "%)"}})
    end
    if r and r.dt then fn.dt_feedback(r.wtype, true, nil) end
    shots[s.id] = nil
    if fn.get(m.rage.resolver, true) and s.target then fn.learn(s.target, true, s.hitgroup == 1, nil) end
end)

client.set_event_callback("aim_miss", function(s)
    local r = shots[s.id]
    if r and fn.get(m.utils.logs) and fn.contains(fn.get(m.utils.log_types, {}), "Miss") then
        fn.log_segments({{fn.color(255, 70, 70), "Missed "}, {fn.color(250, 200, 140), r.name or "?"}, {fn.color(200, 200, 200), "'s " .. (r.aimed or "?") .. " due to " .. (s.reason or "?") .. " (bt: " .. history_ticks .. ") (hc: " .. chance_of_hit .. "%)"}})
    end
    if r and r.snap and fn.get(m.utils.miss_logs) then
        local n = r.snap
        local Y = function(b) return b and "Y" or "n" end
        client.color_log(255, 90, 90, s_format("[CY-MISS] %s | %s | aimed %s | wanted %d dmg @ %d%% hc", r.name or "?", s.reason or "?", r.aimed or "?", r.dmg or 0, m_floor(s.hit_chance or 0)))
        client.color_log(200, 200, 255, s_format("  resolver: src=%s forced=%.1f side=%+d mag=%.1f stage=%d resolved=%s conf=%.0f sscore=%+d", n.r_src or "?", n.r_yaw or 0, n.r_side or 0, n.r_mag or 0, n.r_bidx or 0, Y(n.r_resolved), n.r_conf or 0, n.p_sscore or 0))
        client.color_log(180, 255, 200, s_format("  target: state=%s anim=%s eye=%.1f goalfeet=%.1f desync=%.1f choke=%d pitch=%.0f jit=%s tele=%s", n.p_state and CY.SNAME[n.p_state] or "?", Y(n.p_anim), n.p_eye or 0, n.p_gf or 0, n.p_desync or 0, n.p_choke or 0, n.p_pitch or 0, n.p_jit or "?", Y(n.p_tele)))
        fn.miss_stats(s.reason, n)
    end
    if r and r.dt then fn.dt_feedback(r.wtype, false, s.reason) end
    shots[s.id] = nil
    if fn.get(m.rage.resolver, true) and s.target then fn.learn(s.target, false, false, s.reason) end
end)

client.set_event_callback("bullet_impact", function(ev)
    if not fn.get(m.rage.resolver, true) then return end
    local me = client.userid_to_entindex(ev.userid)
    if not me or me ~= e_local() then return end
    local mx, my, mz = e_origin(me); if not mx then return end
    local dx, dy, dz = ev.x - mx, ev.y - my, ev.z - mz
    local mag = m_sqrt(dx * dx + dy * dy + dz * dz); if mag < 1 then return end
    dx, dy, dz = dx / mag, dy / mag, dz / mag
    local best, berr = nil, 1e9
    for _, en in ipairs(e_players(true)) do
        if not e_dormant(en) then
            local hx, hy, hz = e_hitbox(en, 0)
            if hx then
                local vx, vy, vz = hx - mx, hy - my, hz - mz
                local t = vx * dx + vy * dy + vz * dz
                if t > 0 then
                    local ex, ey, ez = mx + dx * t - hx, my + dy * t - hy, mz + dz * t - hz
                    local err = m_sqrt(ex * ex + ey * ey + ez * ez)
                    if err < berr then berr, best = err, en end
                end
            end
        end
    end
    if best and berr > 8 then fn.learn(best, false, false, "?") end
end)

client.set_event_callback("round_prestart", function()
    if fn.get(m.utils.buybot) then
        local c = "buy " .. fn.get(m.utils.primary, " ") .. "; buy " .. fn.get(m.utils.pistol, " ") .. "; "
        for _, v in ipairs(fn.get(m.utils.nade, {})) do c = c .. "buy " .. v .. "; " end
        for _, v in ipairs(fn.get(m.utils.extra, {})) do c = c .. "buy " .. v .. "; " end
        client.exec(c)
    end
    fn.clear_ents(); fn.tb_reset(); fn.restore()
    fn.console_filter(fn.get(m.utils.console_filter))
end)

client.set_event_callback("player_death", function(ev)
    local uid = ev and ev.userid
    if not uid then return end
    local ent = client.userid_to_entindex(uid)
    if ent then fn.clear_ent(ent) end
    fn.restore()
    if fn.get(m.utils.trashtalk) then
        local me = e_local(); if not me then return end
        local victim = client.userid_to_entindex(ev.userid)
        local attacker = client.userid_to_entindex(ev.attacker)
        if victim ~= attacker and attacker == me then
            client.delay_call(0.6, client.exec, "say " .. ru_trashtalk[m_random(1, #ru_trashtalk)])
        end
    end
end)

for _, n in ipairs({"cs_game_disconnected", "client_disconnect", "game_newmap", "cs_match_end_restart"}) do
    client.set_event_callback(n, function() fn.clear_ents(); fn.tb_reset(); fn.restore(); fn.rage_restore_all() end)
end

client.set_event_callback("level_init", function() fn.console_filter(fn.get(m.utils.console_filter)) end)
client.set_event_callback("pre_config_save", fn.rage_restore_all)

client.set_event_callback("shutdown", function()
    fn.restore()
    fn.rage_restore_all()
    fn.menu_hide_builtin(true)
    cvar.r_aspectratio:set_float(0)
    cvar.cam_idealdist:set_int(150)
    cvar.cl_righthand:set_int(1)
    fn.baim_release()
    if ref.player_reset then fn.set(ref.player_reset, true) end
    client.set_clan_tag("")
end)

client.color_log(250, 200, 140, "[CocoYaw v" .. version .. "] Full build online - new UI, resolver, backtrack, exploits, adaptive hitscale, spread + tickbase guard.")
