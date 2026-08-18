-- CocoYaw v5 fixed - resolver / correction / prediction layer for GameSense
-- New tabbed UI, GameSense Lua API handles, safe overrides, on-shot fix.

local vector = require("vector")
local ffi = require("ffi")

local clipboard_ok, clipboard = pcall(require, "gamesense/clipboard")
if not clipboard_ok then clipboard = nil end

local entity_lib_ok, entity_lib = pcall(require, "gamesense/entity")
if not entity_lib_ok then entity_lib = nil end

local lua_name, build, version = "cocoyaw", "private", "5.0-fixed"

local m_sqrt, m_abs, m_floor = math.sqrt, math.abs, math.floor
local m_atan2, m_deg, m_rad = math.atan2, math.deg, math.rad
local m_random, m_min, m_max = math.random, math.min, math.max
local m_cos, m_sin = math.cos, math.sin
local b_band, b_lshift = bit.band, bit.lshift
local t_remove, t_insert = table.remove, table.insert
local s_format = string.format

local e_prop = entity.get_prop
local e_origin = entity.get_origin
local e_dormant = entity.is_dormant
local e_alive = entity.is_alive
local e_players = entity.get_players
local e_local = entity.get_local_player
local e_hitbox = entity.hitbox_position
local e_weapon = entity.get_player_weapon
local e_class = entity.get_classname
local g_tick = globals.tickcount
local g_curtime = globals.curtime
local g_realtime = globals.realtime
local c_eye = client.eye_position
local c_trace_b = client.trace_bullet
local c_trace_l = client.trace_line
local c_threat = client.current_threat
local p_set = plist.set

local TICK_IV = globals.tickinterval()
local TICK_INV = 1 / TICK_IV

local function safe_call(fn, ...)
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end

local function refs(tab, container, name)
    local out = {pcall(ui.reference, tab, container, name)}
    if not out[1] then return {} end
    t_remove(out, 1)
    return out
end

local function get(ref, fallback)
    if ref == nil then return fallback end
    local ok, v = pcall(ui.get, ref)
    if ok then return v end
    return fallback
end

local function set(ref, value, ...)
    if ref ~= nil then pcall(ui.set, ref, value, ...) end
end

local function vis(ref, value)
    if ref ~= nil then pcall(ui.set_visible, ref, value) end
end

local function contains(list, value)
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        if list[i] == value then return true end
    end
    return false
end

local function randf(lo, hi)
    if hi < lo then lo, hi = hi, lo end
    if client.random_float then return client.random_float(lo, hi) end
    return lo + math.random() * (hi - lo)
end

local function clamp(x, lo, hi)
    return x < lo and lo or (x > hi and hi or x)
end

local function norm(a)
    return (a + 180) % 360 - 180
end

local function delta(a, b)
    return (a - b + 180) % 360 - 180
end

local function ticks(t)
    return m_floor(0.5 + t * TICK_INV)
end

local function color(...)
    local c = {r = 255, g = 255, b = 255, a = 255}
    local n = select("#", ...)
    if n == 0 or n > 4 then return c end
    local v = {...}
    for i = 1, n do
        if type(v[i]) ~= "number" then return c end
    end
    c.r = clamp(v[1], 0, 255)
    c.g = clamp(v[2] or c.r, 0, 255)
    c.b = clamp(v[3] or c.g, 0, 255)
    c.a = clamp(v[4] or 255, 0, 255)
    return c
end

local function log_segments(parts)
    for i = 1, #parts do
        local p = parts[i]
        client.color_log(p[1].r, p[1].g, p[1].b, tostring(p[2]) .. (i == #parts and "\n" or "\0"))
    end
end

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
    EYE_YAW = 0x078, PITCH = 0x07C, GOAL_FEET = 0x080,
    DUCK_AMT = 0x0A4, FEET_SPD_A = 0x0F8, FEET_SPD_B = 0x0FC,
    ON_GROUND = 0x108, HIT_GROUND = 0x109, HEAD_HEIGHT = 0x118,
    STOP_FULL = 0x11C, MAX_YAW = 0x334,
}
local AL = {STRIDE = 0x38, SEQUENCE = 0x18, PREV_CYCLE = 0x1C, WEIGHT = 0x20, PLAYBACK = 0x28, CYCLE = 0x2C}
local TY = {
    f = ffi.typeof("float*"), b = ffi.typeof("bool*"), u = ffi.typeof("uint32_t*"),
    c = ffi.typeof("char*"), cc = ffi.typeof("char**"), vt = ffi.typeof("void***"),
}
local cast = ffi.cast
local function ASF(base, off) return cast(TY.f, base + off)[0] end
local function ASB(base, off) return cast(TY.b, base + off)[0] end
local function ALF(base, off) return cast(TY.f, base + off)[0] end
local function ALFS(base, off, v) cast(TY.f, base + off)[0] = v end
local function ALI(base, off) return cast(TY.u, base + off)[0] end
local function ALIS(base, off, v) cast(TY.u, base + off)[0] = v end

local entlist
for _, dll in ipairs({"client_panorama.dll", "client.dll"}) do
    local ok, iface = pcall(client.create_interface, dll, "VClientEntityList003")
    if ok and iface ~= nil then entlist = iface; break end
end
if entlist == nil then error("VClientEntityList003 not found") end

local entlist_vt = cast(TY.vt, entlist)
local getent = cast(ffi.typeof("void*(__thiscall*)(void*, int)"), entlist_vt[0][3])

local function entptr(idx)
    if idx == nil then return nil end
    local ok, p = pcall(getent, entlist, idx)
    if ok then return p end
end

local function animbase(idx)
    local p = entptr(idx)
    if p == nil then return nil end
    local ok, base = pcall(function()
        local s = cast(TY.cc, cast(TY.c, p) + STATE_OFF)[0]
        return s ~= nil and cast(TY.c, s) or nil
    end)
    return ok and base or nil
end

local function layerbase(idx, i)
    local p = entptr(idx)
    if p == nil then return nil end
    local ok, base = pcall(function()
        local lp = cast(TY.cc, cast(TY.c, p) + LAYER_OFF)
        if lp == nil or lp[0] == nil then return nil end
        return cast(TY.c, lp[0]) + i * AL.STRIDE
    end)
    return ok and base or nil
end

local MAX_YAW_FALLBACK = 58
local function valid_angle(v)
    return type(v) == "number" and v == v and v >= -181 and v <= 181
end

local function max_desync(base)
    if base == nil then return nil end
    local ok, v = pcall(function()
        local duck, sfrac, sfact = ASF(base, AS.DUCK_AMT), ASF(base, AS.FEET_SPD_A), ASF(base, AS.FEET_SPD_B)
        if duck ~= duck or sfrac ~= sfrac or sfact ~= sfact then return nil end
        if duck < -0.01 or duck > 1.01 or sfrac < -0.01 or sfrac > 1.5 or sfact < -0.01 or sfact > 1.5 then return nil end
        local maxy = ASF(base, AS.MAX_YAW)
        if maxy ~= maxy or maxy < 45 or maxy > 62 then maxy = MAX_YAW_FALLBACK end
        local stfr = ASF(base, AS.STOP_FULL)
        if stfr ~= stfr or stfr < -0.01 or stfr > 1.01 then stfr = clamp(sfrac, 0, 1) end
        sfrac, sfact = clamp(sfrac, 0, 1), clamp(sfact, 0, 1)
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
    MOVE_YAW = 7, BLEND_CROUCH = 8, BLEND_WALK = 9, BLEND_RUN = 10,
    BODY_YAW = 11, BODY_PITCH = 12,
}

local function pose_body(ent)
    local p = e_prop(ent, "m_flPoseParameter", PZ.BODY_YAW)
    if type(p) ~= "number" then return nil end
    return clamp(p * 120 - 60, -60, 60)
end

local ref = {
    AA = {
        enabled = refs("AA", "Anti-aimbot angles", "Enabled")[1],
        pitch = refs("AA", "Anti-aimbot angles", "Pitch"),
        yawbase = refs("AA", "Anti-aimbot angles", "Yaw Base")[1],
        yaw = refs("AA", "Anti-aimbot angles", "Yaw"),
        jitter = refs("AA", "Anti-aimbot angles", "Yaw jitter"),
        bodyyaw = refs("AA", "Anti-aimbot angles", "Body Yaw"),
        fsbodyyaw = refs("AA", "Anti-aimbot angles", "Freestanding body yaw")[1],
        edgeyaw = refs("AA", "Anti-aimbot angles", "Edge yaw")[1],
        freestand = refs("AA", "Anti-aimbot angles", "Freestanding"),
        roll = refs("AA", "Anti-aimbot angles", "Roll")[1],
    },
    FL = {
        enabled = refs("AA", "Fake lag", "Enabled"),
        amount = refs("AA", "Fake lag", "Amount")[1],
        variance = refs("AA", "Fake lag", "Variance")[1],
        limit = refs("AA", "Fake lag", "Limit")[1],
    },
    slow = refs("AA", "Other", "Slow motion"),
    leg = refs("AA", "Other", "Leg movement")[1],
    hideshots = refs("AA", "Other", "On shot anti-aim"),
    doubletap = refs("RAGE", "Aimbot", "Double tap"),
    rage = refs("RAGE", "Aimbot", "Enabled"),
    hitchance = refs("RAGE", "Aimbot", "Minimum hit chance")[1],
    mindmg = refs("RAGE", "Aimbot", "Minimum damage")[1],
    mindmg_override = refs("RAGE", "Aimbot", "Minimum damage override"),
    mpscale = refs("RAGE", "Aimbot", "Multi-point scale")[1],
    dthc = refs("RAGE", "Aimbot", "Double tap hit chance")[1],
    wtype = refs("RAGE", "Weapon type", "Weapon type")[1],
    autopeek = refs("RAGE", "Other", "Quick peek assist"),
    forcebaim = refs("RAGE", "Aimbot", "Force body aim")[1],
    safepoint = refs("RAGE", "Aimbot", "Force safe point")[1],
    autostrafe = refs("MISC", "Movement", "Air strafe")[1],
    clantag = refs("Misc", "Miscellaneous", "Clan tag spammer")[1],
    feature_inds = refs("Visuals", "Other ESP", "Feature indicators")[1],
    player_reset = refs("Players", "Players", "Reset All")[1],
    plist_force_body = refs("Players", "Adjustments", "Force Body Yaw")[1],
    plist_corr = refs("Players", "Adjustments", "Correction Active")[1],
}

local OVR = {}
local function ovr(ref_, value)
    if ref_ == nil then return end
    if OVR[ref_] == nil then OVR[ref_] = get(ref_) end
    set(ref_, value)
end

local function restore()
    for r, v in pairs(OVR) do
        set(r, v)
        OVR[r] = nil
    end
end

local tabs = {"Home", "Anti-Aims", "Ragebot", "Utils", "Visuals"}
local conditions = {"Shared", "Standing", "Running", "Walking", "Aerobic", "Aerobic+", "Ducking", "Sneaking"}
local CIDX = {Shared = 1, Standing = 2, Running = 3, Walking = 4, Aerobic = 5, ["Aerobic+"] = 6, Ducking = 7, Sneaking = 8}

local ui_tab = ui.new_combobox("AA", "Anti-aimbot angles", "\vCocoYaw tab", tabs)
local ui_sub = ui.new_combobox("AA", "Anti-aimbot angles", "\nCocoYaw AA page", "Misc", "Builder")
local ui_state = ui.new_combobox("AA", "Anti-aimbot angles", "CocoYaw state", conditions)
local controls = {all = {ui_tab}, home = {}, aa_misc = {ui_sub}, aa_builder = {ui_sub, ui_state}, rage = {}, utils = {}, visuals = {}}
local function add(bucket, item) controls[bucket][#controls[bucket] + 1] = item; return item end

add("home", ui.new_label("AA", "Anti-aimbot angles", "\vCocoYaw v5 fixed"))
add("home", ui.new_label("AA", "Anti-aimbot angles", "resolver reads over inference"))

local aa_misc = {
    yaw_base = add("aa_misc", ui.new_combobox("AA", "Anti-aimbot angles", "CY yaw base", "At targets", "Local view")),
    tweaks = add("aa_misc", ui.new_multiselect("AA", "Anti-aimbot angles", "CY tweaks", "Anti Backstab", "Edge Yaw on FD", "Static on Manual", "Disable Roll on Auto Peek", "Static on TP/Recharge", "Micro Movement")),
    fl_active = add("aa_misc", ui.new_checkbox("AA", "Anti-aimbot angles", "CY fake lag")),
    fl_limit = add("aa_misc", ui.new_slider("AA", "Anti-aimbot angles", "CY fake lag limit", 1, 16, 14, true, "t")),
    desync_inverter = add("aa_misc", ui.new_hotkey("AA", "Anti-aimbot angles", "CY desync inverter")),
    freestand = add("aa_misc", ui.new_hotkey("AA", "Anti-aimbot angles", "CY freestanding")),
    manual_left = add("aa_misc", ui.new_hotkey("AA", "Anti-aimbot angles", "CY manual left")),
    manual_right = add("aa_misc", ui.new_hotkey("AA", "Anti-aimbot angles", "CY manual right")),
    manual_forward = add("aa_misc", ui.new_hotkey("AA", "Anti-aimbot angles", "CY manual forward")),
    defensive_risk = add("aa_misc", ui.new_combobox("AA", "Anti-aimbot angles", "CY defensive risk", "High", "Medium", "Low", "Safest")),
    ext_def = add("aa_misc", ui.new_hotkey("AA", "Anti-aimbot angles", "CY extended defensive")),
    ext_def_hit = add("aa_misc", ui.new_hotkey("AA", "Anti-aimbot angles", "CY ext defensive on hittable")),
    leg_breaker = add("aa_misc", ui.new_checkbox("AA", "Anti-aimbot angles", "CY leg breaker")),
    tweak_aa = add("aa_misc", ui.new_checkbox("AA", "Anti-aimbot angles", "CY break animations")),
    tweak_opts = add("aa_misc", ui.new_multiselect("AA", "Anti-aimbot angles", "CY animation breaks", "Extreme body lean", "Lean jitter", "Speed scaled lean", "On-shot spike", "Freestand lean", "Defensive boost", "Air walk", "Earthquake", "Fake walk", "Moonwalk", "Smoothing", "Fallen legs", "Slide", "Fake duck", "Fake flash", "Break legs", "Break move yaw", "Air desync", "Land pitch break")),
    tweak_lean = add("aa_misc", ui.new_slider("AA", "Anti-aimbot angles", "CY body lean", 0, 1000, 100, true, "%", 0.01)),
    tweak_defmul = add("aa_misc", ui.new_slider("AA", "Anti-aimbot angles", "CY defensive multiplier", 100, 400, 250, true, "%", 0.01)),
}

local aa = {}
for i = 1, #conditions do
    aa[i] = {
        enabled = add("aa_builder", ui.new_checkbox("AA", "Anti-aimbot angles", "CY enable " .. conditions[i])),
        pitch = add("aa_builder", ui.new_combobox("AA", "Anti-aimbot angles", "CY pitch " .. conditions[i], "Off", "Default", "Up", "Down", "Minimal", "Random")),
        yawbase = add("aa_builder", ui.new_combobox("AA", "Anti-aimbot angles", "CY yaw base " .. conditions[i], "Local view", "At targets")),
        yaw = add("aa_builder", ui.new_combobox("AA", "Anti-aimbot angles", "CY yaw " .. conditions[i], "Off", "Static", "Switch")),
        yaw_static = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY yaw value " .. conditions[i], -180, 180, 0, true, "°")),
        yaw_left = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY left value " .. conditions[i], -180, 180, 0, true, "°")),
        yaw_right = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY right value " .. conditions[i], -180, 180, 0, true, "°")),
        random = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY yaw random " .. conditions[i], 0, 100, 0, true, "%")),
        mods = add("aa_builder", ui.new_multiselect("AA", "Anti-aimbot angles", "CY modifiers " .. conditions[i], "Jitter", "Sway", "Spin", "Slow Jitter")),
        jit_min = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY jitter min " .. conditions[i], -90, 90, 0, true, "°")),
        jit_max = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY jitter max " .. conditions[i], -90, 90, 0, true, "°")),
        sway_amount = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY sway amount " .. conditions[i], 0, 90, 0, true, "°")),
        sway_speed = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY sway speed " .. conditions[i], 0, 30, 0)),
        spin_amount = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY spin amount " .. conditions[i], 0, 360, 0, true, "°")),
        spin_speed = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY spin speed " .. conditions[i], 0, 30, 0)),
        slow_amount = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY slow jitter amount " .. conditions[i], 0, 90, 45, true, "°")),
        slow_period = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY slow jitter period " .. conditions[i], 2, 8, 3)),
        desync = add("aa_builder", ui.new_combobox("AA", "Anti-aimbot angles", "CY desync " .. conditions[i], "Off", "Jitter", "Static")),
        desync_amount = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY desync amount " .. conditions[i], 0, 120, 60, true, "°")),
        bodyyaw = add("aa_builder", ui.new_checkbox("AA", "Anti-aimbot angles", "CY body yaw " .. conditions[i])),
        body_jitter = add("aa_builder", ui.new_checkbox("AA", "Anti-aimbot angles", "CY body jitter " .. conditions[i])),
        roll = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY roll " .. conditions[i], -45, 45, 0, true, "°")),
        defensive = add("aa_builder", ui.new_checkbox("AA", "Anti-aimbot angles", "CY defensive " .. conditions[i])),
        force_def = add("aa_builder", ui.new_checkbox("AA", "Anti-aimbot angles", "CY force defensive " .. conditions[i])),
        def_pitch = add("aa_builder", ui.new_combobox("AA", "Anti-aimbot angles", "CY defensive pitch " .. conditions[i], "Off", "Up", "Down", "Zero", "Random")),
        def_yaw = add("aa_builder", ui.new_combobox("AA", "Anti-aimbot angles", "CY defensive yaw " .. conditions[i], "Off", "Forward", "Spin", "Jitter", "Opposite", "Static")),
        def_amount = add("aa_builder", ui.new_slider("AA", "Anti-aimbot angles", "CY defensive amount " .. conditions[i], -180, 180, 0, true, "°")),
    }
end
set(aa[1].enabled, true)

local rage = {
    resolver = add("rage", ui.new_checkbox("RAGE", "Other", "CY enable resolver")),
    onshot = add("rage", ui.new_checkbox("RAGE", "Other", "CY on-shot angle capture")),
    maxdes = add("rage", ui.new_checkbox("RAGE", "Other", "CY engine desync ceiling")),
    pgate = add("rage", ui.new_checkbox("RAGE", "Other", "CY pitch gate")),
    pose = add("rage", ui.new_checkbox("RAGE", "Other", "CY pose fallback")),
    hs = add("rage", ui.new_checkbox("RAGE", "Other", "CY adaptive hitscale")),
    hs_dmg = add("rage", ui.new_checkbox("RAGE", "Other", "CY adaptive lethal damage")),
    spread = add("rage", ui.new_checkbox("RAGE", "Other", "CY spread guard")),
    spread_strength = add("rage", ui.new_slider("RAGE", "Other", "CY spread strength", 0, 150, 100, true, "%")),
    dthc = add("rage", ui.new_checkbox("RAGE", "Other", "CY adaptive DT hitchance")),
    dthc_off = add("rage", ui.new_slider("RAGE", "Other", "CY DT HC offensive", 0, 100, 30, true, "%")),
    dthc_def = add("rage", ui.new_slider("RAGE", "Other", "CY DT HC defensive", 0, 100, 55, true, "%")),
    dt_recharge = add("rage", ui.new_checkbox("RAGE", "Other", "CY better DT recharge")),
    fix_autopeek = add("rage", ui.new_checkbox("RAGE", "Other", "CY fix auto peek")),
    jump_scout = add("rage", ui.new_checkbox("RAGE", "Other", "CY jump scout")),
    scout_hc = add("rage", ui.new_slider("RAGE", "Other", "CY scout HC", 0, 100, 75, true, "%")),
    jump_hc = add("rage", ui.new_slider("RAGE", "Other", "CY jump HC", 0, 100, 40, true, "%")),
    auto_hs = add("rage", ui.new_checkbox("RAGE", "Other", "CY auto Hide-Shots")),
    auto_hs_wep = add("rage", ui.new_multiselect("RAGE", "Other", "CY HS disable weapons", "Scout", "AWP", "Auto", "Deagle & R8")),
    auto_hs_state = add("rage", ui.new_multiselect("RAGE", "Other", "CY HS states", "Standing", "Walking", "Ducking", "Sneaking")),
    hideshot_fix = add("rage", ui.new_checkbox("RAGE", "Other", "CY Hide-Shots fix")),
}
set(rage.resolver, true); set(rage.onshot, true); set(rage.maxdes, true); set(rage.pgate, true); set(rage.pose, true); set(rage.spread, true)

local utils = {
    logs = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY shot logs")),
    log_types = add("utils", ui.new_multiselect("MISC", "Miscellaneous", "CY log type", "Hit", "Miss")),
    miss_logs = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY full miss logs")),
    miss_dump = add("utils", ui.new_hotkey("MISC", "Miscellaneous", "CY dump miss stats", true)),
    buybot = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY buybot")),
    primary = add("utils", ui.new_combobox("MISC", "Miscellaneous", "CY primary", " ", "awp", "ssg08", "scar20", "g3sg1", "ak47", "m4a1", "m4a1_silencer", "aug", "famas", "sg556")),
    pistol = add("utils", ui.new_combobox("MISC", "Miscellaneous", "CY pistol", " ", "deagle", "elite", "tec9", "p250", "fn57")),
    nade = add("utils", ui.new_multiselect("MISC", "Miscellaneous", "CY nades", "molotov", "hegrenade", "smokegrenade", "decoy", "flashbang")),
    extra = add("utils", ui.new_multiselect("MISC", "Miscellaneous", "CY extras", "vesthelm", "taser", "defuser", "vest")),
    clantag = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY clantag")),
    trashtalk = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY trashtalk")),
    fast_ladder = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY fast ladder")),
    thirdperson = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY thirdperson distance")),
    thirdperson_dist = add("utils", ui.new_slider("MISC", "Miscellaneous", "CY distance", 25, 230, 150, true, "u")),
    aspect = add("utils", ui.new_checkbox("MISC", "Miscellaneous", "CY aspect ratio")),
    aspect_value = add("utils", ui.new_slider("MISC", "Miscellaneous", "CY aspect value", 0, 200, 0, true, "x", 0.01)),
}

local visuals = {
    indicators = add("visuals", ui.new_checkbox("VISUALS", "Other ESP", "CY indicators")),
    arrows = add("visuals", ui.new_checkbox("VISUALS", "Other ESP", "CY manual arrows")),
    damage = add("visuals", ui.new_checkbox("VISUALS", "Other ESP", "CY damage indicator")),
    defensive = add("visuals", ui.new_checkbox("VISUALS", "Other ESP", "CY defensive indicator")),
    watermark = add("visuals", ui.new_checkbox("VISUALS", "Other ESP", "CY watermark")),
}

local function update_visible()
    local tab, sub, state = get(ui_tab), get(ui_sub), get(ui_state)
    for _, list in pairs(controls) do
        for i = 1, #list do vis(list[i], false) end
    end
    for i = 1, #controls.all do vis(controls.all[i], true) end
    local bucket = tab == "Home" and "home" or tab == "Ragebot" and "rage" or tab == "Utils" and "utils" or tab == "Visuals" and "visuals" or nil
    if bucket then
        for i = 1, #controls[bucket] do vis(controls[bucket][i], true) end
    elseif tab == "Anti-Aims" then
        local list = sub == "Builder" and controls.aa_builder or controls.aa_misc
        for i = 1, #list do vis(list[i], true) end
        if sub == "Builder" then
            for idx = 1, #conditions do
                local show = conditions[idx] == state
                for _, item in pairs(aa[idx]) do vis(item, show) end
            end
        end
    end
end
for _, item in ipairs({ui_tab, ui_sub, ui_state}) do ui.set_callback(item, update_visible) end
update_visible()

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

local function clear_ents() for k in pairs(ents) do ents[k] = nil end end
local function clear_ent(i) ents[i] = nil end

local function physics(idx)
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

local function history(idx)
    local e = ents[idx]
    if not e then e = {}; ents[idx] = e end
    if e.h then return e.h end
    local h = {ht = 0, ms = 0, ns = 0, cf = 0, cft = 0, hb = {}, mb = {}, g = {}, bd = {}, sh = {}, sm = {}}
    for _, s in pairs(ST) do if type(s) == "number" then h.hb[s] = 0; h.mb[s] = 0 end end
    for i = 1, CY.STAGES do h.sh[i] = 0; h.sm[i] = 0 end
    e.h = h
    return h
end

local function progress(idx)
    local e = ents[idx]
    if not e then e = {}; ents[idx] = e end
    if e.pr then return e.pr end
    local n = g_realtime()
    e.pr = {s = 1, p = 0, t0 = n, l = n, r = false}
    return e.pr
end

local function brute(idx)
    local e = ents[idx]
    if not e then e = {}; ents[idx] = e end
    if e.b then return e.b end
    e.b = {i = 1, mr = 0, cy = 0}
    return e.b
end

local function ring_push(ring, val, cap)
    ring.w = ring.w % cap + 1
    if ring.n >= cap then ring.s = ring.s - (ring.d[ring.w] or 0) else ring.n = ring.n + 1 end
    ring.d[ring.w] = val
    ring.s = ring.s + val
end

local function classify(pd)
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
        pd.jit = "jitter2"; pd.jitc = clamp(1 - (m_abs(d02) / CY.JIT_RETURN) * 0.5, 0.5, 1.0)
    elseif step > CY.JIT_RETURN or m_abs(d12) > CY.JIT_RETURN or m_abs(d23) > CY.JIT_RETURN then
        pd.jit = "skitter"; pd.jitc = clamp(step / 60, 0.3, 1.0)
    else
        pd.jit = "unknown"; pd.jitc = 0
    end
end

local mg = {
    lp = {id = -1, origin = vector(), speedxy = 0, speedz = 0, duck = false, tickbase = 0},
    state = "Standing", weaponid = 0, weaponname = "", weaponswitch = false,
    exploit = "", declaredloc = vector(), currentloc = vector(), declaredyaw = 0, fakeyaw = 0,
    shottimer = 0, shotbool = false, jumpscout = false, autopeekfix = 0,
    threat = -1, fsside = nil, fsyaw = nil, hittable_any = false, indefensive = false, ext_fired = false,
    tb = {cmd = nil, max = nil, diff = nil, depth = 0}, own_max = 58, fl_phase = 0,
}

local function acquire(ent)
    local pd = physics(ent)
    local now = g_curtime()
    if e_dormant(ent) then
        if not pd.dm then pd.dm = true; pd.dmt = now end
        return pd
    end
    if pd.dm then
        pd.dm = false; pd.dh = {}; pd.hist = {}; pd.histn = 0; pd.db = {d = {}, w = 0, n = 0, s = 0}; pd.ovalid = false
    end

    local esp = entity.get_esp_data and entity.get_esp_data(ent) or nil
    local ef = (esp and esp.flags) or 0
    pd.tele = b_band(ef, CY.ESP_TELEPORT) ~= 0
    pd.hittable = b_band(ef, CY.ESP_HITTABLE) ~= 0

    local sim = e_prop(ent, "m_flSimulationTime") or now
    local simt = ticks(sim) - (pd.tele and 14 or 0)
    if pd.simt ~= 0 and simt - pd.simt < 1 then return pd end
    pd.psimt, pd.simt = pd.simt, simt
    if pd.psm > 0 and pd.sok then
        local sd = sim - pd.psm
        if sd > 0 then pd.chk = clamp(m_floor(sd * TICK_INV + 0.5), 1, 16) end
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
    local et, et2 = TICK_IV * CY.EXTRAP_TICKS, (TICK_IV * CY.EXTRAP_TICKS) ^ 2
    pd.prx = pd.px + vx * et + pd.ax * (et2 * CY.ACCEL_W) + pd.jx * (et2 * et * 0.15)
    pd.pry = pd.py + vy * et + pd.ay * (et2 * CY.ACCEL_W) + pd.jy * (et2 * et * 0.15)
    pd.prz = pd.pz + vz * et + pd.az * (et2 * CY.ACCEL_W) + pd.jz * (et2 * et * 0.15)

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

    local ast = animbase(ent)
    pd.hasanim, pd.maxdes_ok = false, false
    if ast then
        pcall(function()
            local gf, ey = ASF(ast, AS.GOAL_FEET), ASF(ast, AS.EYE_YAW)
            if valid_angle(gf) then
                local anchor = valid_angle(ey) and ey or pd.aw
                local d = delta(anchor, gf)
                if m_abs(d) <= 62 then pd.gf = gf; pd.hasanim = true; if valid_angle(ey) then pd.aw = ey end; pd.ds = d end
            end
        end)
        local md = max_desync(ast)
        if md then pd.maxdes = md; pd.maxdes_ok = true; pd.maxdes_t = now end
    end
    if not pd.maxdes_ok and pd.maxdes_t > 0 and now - pd.maxdes_t < 1.5 then pd.maxdes_ok = true end
    local pv = pose_body(ent)
    if pv ~= nil then
        pd.pose, pd.pose_ok = pv, true
        if m_abs(pv) > CY.POSE_MIN then pd.pbody = norm(pd.aw - pv); pd.pbody_ok = true else pd.pbody = pd.aw; pd.pbody_ok = false end
    else
        pd.pose_ok, pd.pbody_ok = false, false
    end
    if not pd.hasanim then pd.ds = pd.pbody_ok and pd.pose or delta(pd.aw, pd.lby) end
    pd.dss = pd.ds > 0 and 1 or -1
    t_insert(pd.dh, 1, pd.ds); if #pd.dh > CY.HIST then t_remove(pd.dh) end
    classify(pd)

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
            if half > 0.02 and half < 2 then pd.swh = pd.swh > 0 and (pd.swh + (half - pd.swh) * 0.4) or half end
        end
        pd.sf = pd.sf + 1; pd.swt = now
    end
    if now - pd.swt > 2 then pd.sf = m_max(0, pd.sf - 1) end
    pd.swd = pd.sf >= CY.SWAY_THRESH

    local spd2 = m_sqrt(vx * vx + vy * vy)
    local ld = m_abs(delta(pd.lby, pd.plby))
    pd.lbu = false
    if ld > 2 and spd2 < 5 then
        pd.lbu = true; pd.lbt = g_tick(); pd.lbv = pd.lby
        pd.lbs[#pd.lbs + 1] = now; if #pd.lbs > 8 then t_remove(pd.lbs, 1) end
        if #pd.lbs >= 2 then
            local s, c = 0, 0
            for i = 2, #pd.lbs do s = s + pd.lbs[i] - pd.lbs[i - 1]; c = c + 1 end
            pd.lba = s / c; pd.lbn = now + pd.lba
        else pd.lbn = now + CY.LBY_BASE end
    end

    pd.ml = spd2 > 15
    if pd.ml then pd.my = m_deg(m_atan2(vy, vx)) end
    ring_push(pd.db, m_abs(pd.ds), CY.SAMPLES)
    pd.ad = pd.db.n > 0 and pd.db.s / pd.db.n or 0
    pd.ls = m_abs(pd.ds) < CY.DEF_DESYNC and (pd.ls + 1) or 0

    for i = 1, 3 do
        local li, l = CY.LAYERS[i], layerbase(ent, CY.LAYERS[i])
        local t = pd.ly[li]
        if l then
            t.ok = pcall(function() t.sq = ALI(l, AL.SEQUENCE); t.pc = ALF(l, AL.PREV_CYCLE); t.w = ALF(l, AL.WEIGHT); t.r = ALF(l, AL.PLAYBACK); t.c = ALF(l, AL.CYCLE) end)
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
    pd.aa = m_abs(pd.ap) > CY.PITCH_GATE or m_abs(pd.ds) > 8 or pd.maxobs > 12 or pd.jit == "jitter2" or pd.jit == "skitter" or pd.chk >= 4 or pd.ovalid or (pd.pose_ok and m_abs(pd.pose) > 8)
    local l6 = pd.ly[6]
    pd.def = pd.sok and pd.chk <= CY.CHOKE_DEF and (pd.st == ST.STANDING or pd.st == ST.CROUCHING) and (pd.ad < CY.DEF_AVG or pd.ls >= CY.DEF_STREAK or (l6.ok and l6.w < CY.DEF_L6 and m_abs(pd.ds) < CY.DEF_DESYNC) or (spd2 < 5 and m_abs(pd.ds) < 8))
    pd.dft = pd.def and pd.dft + 1 or m_max(0, pd.dft - 2)
    pd.lt = now
    return pd
end

local function freestand_enemy(ent, pd, me)
    local ex, ey, ez = c_eye()
    if not ex then return 0 end
    local perp = m_atan2(pd.py - ey, pd.px - ex) + 1.5707963
    local cp, sp = m_cos(perp), m_sin(perp)
    for _, r in ipairs({16, 32}) do
        local ox, oy, hz = cp * r, sp * r, pd.pz + 64
        local lh = c_trace_b(me, ex, ey, ez, pd.px + ox, pd.py + oy, hz)
        local rh = c_trace_b(me, ex, ey, ez, pd.px - ox, pd.py - oy, hz)
        if lh == ent and rh ~= ent then return 1 elseif rh == ent and lh ~= ent then return -1 end
    end
    return 0
end

local function estimate(ent, st)
    local e = ents[ent]; if not e or not e.p then return 0, 1, nil, "none" end
    local pd, tick, now, eye = e.p, g_tick(), g_curtime(), e.p.aw
    if pd.lbu and tick - pd.lbt < CY.LBY_WINDOW then return 0, 1, pd.lby, "lby" end
    local body, src
    if pd.hasanim then body, src = pd.gf, "anim"
    elseif get(rage.pose, true) and pd.pbody_ok then body, src = pd.pbody, "pose" end
    if not body and get(rage.onshot, true) and pd.ovalid and now - pd.ocap < CY.ONSHOT_COMMIT then return 0, 1, pd.oyaw, "onshot" end
    if body then
        local mag, d = m_abs(delta(eye, body)), delta(body, eye)
        local side = m_abs(d) <= 3 and pd.dss or (d > 0 and 1 or -1)
        local sc = pd.sscore[st]
        if sc and m_abs(sc) >= 4 then side = sc > 0 and 1 or -1 end
        if pd.msd ~= 0 and tick < pd.msu and (pd.meas_miss or 0) >= 2 then side = pd.msd end
        if get(rage.maxdes, true) and pd.maxdes_ok then mag = m_min(mag, pd.maxdes) end
        return clamp(mag, 0, 58), side, nil, src
    end
    local step = pd.histn >= 2 and m_abs(delta(pd.hist[1], pd.hist[2])) or 0
    local mag = pd.maxobs > 10 and now - pd.maxobs_t < 8 and pd.maxobs or (step > 8 and clamp(step * 0.9, 12, 58) or (pd.chk >= 10 and CY.FL_MAG_HIGH or (pd.chk >= 6 and CY.FL_MAG_FLOOR or m_max(pd.ad, 5))))
    if pd.lkg_ok and now - pd.lkg_t < 3 then mag = mag + (m_abs(delta(eye, pd.lkg)) - mag) * 0.3 end
    if get(rage.maxdes, true) and pd.maxdes_ok then mag = m_min(mag, pd.maxdes) end
    local side = m_abs(pd.ds) > 3 and pd.dss or 0
    local sc = pd.sscore[st]
    if sc and m_abs(sc) >= 2 and (side == 0 or m_abs(sc) >= 4) then side = sc > 0 and 1 or -1 end
    if pd.fss ~= 0 and tick - pd.fst < 20 then side = pd.fss end
    if pd.msd ~= 0 and tick < pd.msu then side = pd.msd end
    if pd.jit == "skitter" and pd.jitc > CY.JIT_CONF_GATE then mag = mag * 0.55 end
    return clamp(mag, 0, 58), side == 0 and 1 or side, nil, "infer"
end

local function release_resolver(ent)
    p_set(ent, "Correction Active", true)
    p_set(ent, "Force Body Yaw", false)
    p_set(ent, "Force Pitch", false)
end

local function resolve(ent)
    local pd = acquire(ent)
    if pd.st == ST.INVALID or pd.dm then return end
    local e, pr, h = ents[ent], progress(ent), history(ent)
    local now, ct = g_realtime(), g_curtime()
    if now - h.cft > 2 then h.cf = m_max(0, h.cf - CY.CONF_DECAY * (now - h.cft)); h.cft = now end
    local xp = pd.ap < -89 or pd.ap > 89
    local has_reading = pd.hasanim or (get(rage.pose, true) and pd.pbody_ok)
    if not has_reading and get(rage.onshot, true) and pd.ovalid and ct - pd.ocap < CY.ONSHOT_COMMIT then
        p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", true); p_set(ent, "Force Body Yaw Value", pd.oyaw)
        p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
        pr.s, pr.r, e.v = 4, true, {y = pd.oyaw, o = 0, bo = 0, bi = 0, s = pd.dss, st = pd.st, d = false, ad = pd.ad, mag = 0, onshot = true, src = "onshot"}
        pr.l = now; return
    end
    if get(rage.pgate, true) and not pd.aa then
        release_resolver(ent); e.v = {y = pd.aw, o = 0, bo = 0, bi = 0, s = 0, st = pd.st, skipped = true, src = "skip"}; pr.l = now; return
    end
    if ent == mg.threat and pd.st ~= ST.AIR and pd.st ~= ST.AIR_CROUCH then
        local me = e_local()
        if me then local f = freestand_enemy(ent, pd, me); if f ~= 0 then pd.fss = f; pd.fst = g_tick() end end
    end
    pr.p = m_min(100, pr.p + 24 * (now - pr.l) * ((pd.st == ST.STANDING and 2) or (pd.st == ST.AIR and 1.5) or 1))
    local total = h.ht + h.ms
    pr.s = pr.p < 25 and 1 or (pr.p < 50 and 2 or (pr.p < 75 and (total >= CY.MIN_SHOTS and 3 or 2) or ((total >= CY.MIN_SHOTS and h.ht > 0) and 4 or 3)))
    pr.r = pr.s == 4
    if pd.def and pd.dft >= 3 then
        local dy = pd.hasanim and pd.gf or (pd.pbody_ok and pd.pbody or pd.lby)
        p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", true); p_set(ent, "Force Body Yaw Value", dy)
        p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
        e.v = {y = dy, o = 0, bo = 0, bi = 0, s = pd.dss, st = pd.st, d = true, ad = pd.ad, mag = 0, src = "defensive"}
        pr.l = now; return
    end
    local mag, side, override, src = estimate(ent, pd.st)
    local bs = brute(ent)
    if (src == "anim" or src == "pose") and (pd.meas_miss or 0) < 3 then
        local fy = norm(pd.aw + side * mag)
        p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", mag >= 1)
        if mag >= 1 then p_set(ent, "Force Body Yaw Value", fy) end
        p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
        e.v = {y = fy, o = side * mag, bo = mag, bi = 0, s = side, st = pd.st, d = false, ad = pd.ad, mag = mag, src = src, anim = pd.hasanim, maxds = pd.maxdes, maxok = pd.maxdes_ok}
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
    local ceiling = get(rage.maxdes, true) and pd.maxdes_ok and pd.maxdes or 58
    local ext, us, um = m_min(m_max(mag, 52 + (bs.cy >= 2 and 6 or 0)), ceiling), side, mag
    if mode == 2 then us = -side elseif mode == 3 then um = ext elseif mode == 4 then us, um = -side, ext
    elseif mode == 5 then if pd.lbv ~= 0 then override = pd.lbv else um = mag * 0.5 end
    elseif mode == 6 then um = 0
    elseif mode == 7 then if pd.lkg_ok and now - pd.lkg_t < 10 then override = pd.lkg else us, um = -side, ext end end
    um = clamp(um, 0, ceiling)
    local fy = override or norm(pd.aw + us * um)
    p_set(ent, "Correction Active", true); p_set(ent, "Force Body Yaw", um ~= 0 or override ~= nil)
    if um ~= 0 or override ~= nil then p_set(ent, "Force Body Yaw Value", fy) end
    p_set(ent, "Force Pitch", xp); if xp then p_set(ent, "Force Pitch Value", 0) end
    e.v = {y = fy, o = us * um, bo = mag, bi = mode, s = us, st = pd.st, d = false, ad = pd.ad, mag = um, src = src, jit = pd.jit, chk = pd.chk}
    bs.i, pr.l = mode, now
end

local RESOLVER_MISS = {["?"] = true, resolver = true}
local function learn(ent, hit, hs, reason)
    local e = ents[ent]; if not e or not e.p or not e.v or e.v.skipped then return end
    local pd, h, rv = e.p, history(ent), e.v
    local tick = g_tick()
    if e.lt == tick then return end
    e.lt = tick
    local st, off, bidx = pd.st, rv.o or 0, rv.bi or 0
    local blame = hit or reason == nil or RESOLVER_MISS[reason] or false
    h.ns = h.ns + 1
    if rv.s and rv.s ~= 0 and blame then pd.sscore[st] = clamp((pd.sscore[st] or 0) + (hit and rv.s * 2 or -rv.s), -8, 8) end
    if hit then
        h.ht = h.ht + 1; h.hb[st] = (h.hb[st] or 0) + 1; h.cf = m_min(100, h.cf + (hs and 12 or 6))
        h.g[#h.g + 1] = {yaw = rv.y, off = off, st = st, t = g_realtime(), hs = hs, stg = bidx}
        if bidx >= 1 and bidx <= CY.STAGES then h.sh[bidx] = (h.sh[bidx] or 0) + 1 end
        local bs = brute(ent); bs.i = bidx > 0 and bidx or 1; bs.mr = 0
        pd.msd = 0; pd.meas_miss = 0; pd.lkg = rv.y; pd.lkg_t = g_realtime(); pd.lkg_ok = true
    else
        h.ms = h.ms + 1; h.mb[st] = (h.mb[st] or 0) + 1; h.bd[#h.bd + 1] = {yaw = rv.y, off = off, st = st, t = g_realtime(), stg = bidx}
        if not blame then while #h.bd > 48 do t_remove(h.bd, 1) end; return end
        h.cf = m_max(0, h.cf - (6 + m_min(h.ms, 10)))
        if bidx >= 1 and bidx <= CY.STAGES then h.sm[bidx] = (h.sm[bidx] or 0) + 1 end
        local bs = brute(ent); bs.mr = bs.mr + 1; if bs.i >= CY.STAGES then bs.cy = bs.cy + 1 end; bs.i = (bs.i % CY.STAGES) + 1
        pd.msd = (rv.s or 1) > 0 and -1 or 1; pd.msu = tick + CY.MISS_FLIP
        pd.meas_miss = (rv.src == "anim" or rv.src == "pose") and ((pd.meas_miss or 0) + 1) or 0
        local pr = progress(ent); if pr.p < 70 then pr.p = 70 end
        if rv.onshot then pd.ovalid = false end
    end
    while #h.g > 48 do t_remove(h.g, 1) end
    while #h.bd > 48 do t_remove(h.bd, 1) end
end

local function in_defensive()
    local d = mg.tb.diff
    return d ~= nil and d <= -1 and d >= -14
end
local function depth()
    local d = mg.tb.diff
    if d == nil or d >= 0 then return 0 end
    return -d
end
local function charged()
    local d = mg.tb.diff
    return d == nil or d >= 0
end
local function tb_reset() mg.tb.max = nil; mg.tb.diff = nil; mg.tb.cmd = nil; mg.tb.depth = 0 end

local function player_state(cmd)
    local lp = e_local(); if not lp then return "Shared" end
    local vx, vy, vz = e_prop(lp, "m_vecVelocity")
    vx, vy, vz = vx or 0, vy or 0, vz or 0
    local flags = e_prop(lp, "m_fFlags") or 0
    local velocity = m_sqrt(vx * vx + vy * vy)
    local grounded = b_band(flags, CY.FL_GROUND) ~= 0
    local ducked = (e_prop(lp, "m_flDuckAmount") or 0) > 0.7
    if not grounded and ducked then return "Aerobic+" elseif not grounded then return "Aerobic"
    elseif ducked and velocity > 10 then return "Sneaking" elseif ducked then return "Ducking"
    elseif get(ref.slow[1], false) and get(ref.slow[2], false) and velocity > 10 then return "Walking"
    elseif velocity > 5 then return "Running" else return "Standing" end
end

local yaw_direction, last_manual = 0, 0
local function update_manuals()
    local now = g_curtime()
    if get(aa_misc.manual_right) and last_manual + 0.2 < now then yaw_direction = yaw_direction == 90 and 0 or 90; last_manual = now
    elseif get(aa_misc.manual_left) and last_manual + 0.2 < now then yaw_direction = yaw_direction == -90 and 0 or -90; last_manual = now
    elseif get(aa_misc.manual_forward) and last_manual + 0.2 < now then yaw_direction = yaw_direction == 180 and 0 or 180; last_manual = now end
end

local DEF_RISK = {Safest = -4, Low = -3, Medium = -2, High = -1}
local aam = {switch = false, delay = 0, sway = 0, sway_dir = 1, spin = 0, desyncswitch = false, micro = false, microtick = 0}

local function choose_aa(cmd)
    local st = player_state(cmd)
    mg.state = st
    local id = CIDX[st] or 1
    if id ~= 1 and not get(aa[id].enabled, false) then id = 1 end
    return aa[id], id
end

local function setup_aa(cmd)
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    update_manuals()
    local cfg = choose_aa(cmd)
    if not get(cfg.enabled, false) then return end
    ovr(ref.FL.enabled[1], false); ovr(ref.FL.amount, "Maximum")
    if get(aa_misc.fl_active, false) then
        local send = cmd.chokedcommands >= get(aa_misc.fl_limit, 14)
        if mg.shotbool or cmd.chokedcommands >= 15 then send = true; cmd.no_choke = true end
        cmd.allow_send_packet = send
    end
    if cmd.allow_send_packet then mg.declaredloc = vector(e_origin(lp)) end

    local yaw = 0
    if get(cfg.yaw) == "Static" then yaw = randf(get(cfg.yaw_static, 0) * (1 - get(cfg.random, 0) * 0.01), get(cfg.yaw_static, 0) * (1 + get(cfg.random, 0) * 0.01))
    elseif get(cfg.yaw) == "Switch" then yaw = randf(get(cfg.yaw_left, 0), get(cfg.yaw_right, 0)) end
    local mods = get(cfg.mods, {})
    if contains(mods, "Jitter") then
        local j = randf(get(cfg.jit_min, 0), get(cfg.jit_max, 0))
        yaw = yaw + (aam.switch and -j or j)
    end
    if contains(mods, "Sway") then
        local amt, spd = get(cfg.sway_amount, 0), get(cfg.sway_speed, 0)
        if aam.sway >= amt then aam.sway_dir = -1 elseif aam.sway <= -amt then aam.sway_dir = 1 end
        aam.sway = aam.sway + aam.sway_dir * spd
        yaw = yaw + aam.sway
    end
    if contains(mods, "Spin") then
        aam.spin = (aam.spin + get(cfg.spin_speed, 0)) % m_max(get(cfg.spin_amount, 0), 1)
        yaw = yaw + aam.spin
    end
    if contains(mods, "Slow Jitter") then
        yaw = yaw + (mg.fl_phase < get(cfg.slow_period, 3) and get(cfg.slow_amount, 45) * 0.5 or -get(cfg.slow_amount, 45) * 0.5)
    end
    local in_def = in_defensive()
    mg.indefensive, mg.tb.depth = in_def, depth()
    if get(aa_misc.ext_def) or (get(aa_misc.ext_def_hit) and mg.hittable_any) then
        cmd.force_defensive = true
        local risk = DEF_RISK[get(aa_misc.defensive_risk, "High")] or -1
        if not mg.ext_fired and mg.tb.diff ~= nil and mg.tb.diff <= risk then ovr(ref.doubletap[1], false); cmd.force_defensive = false; mg.ext_fired = true end
    elseif mg.tb.diff == nil or mg.tb.diff >= 0 then mg.ext_fired = false end
    if get(cfg.force_def, false) or in_def then cmd.force_defensive = true end
    if in_def and get(cfg.defensive, false) then
        local dy = get(cfg.def_yaw)
        if dy == "Forward" then yaw = 180 elseif dy == "Opposite" then yaw = norm(yaw + 180)
        elseif dy == "Jitter" then yaw = aam.desyncswitch and get(cfg.def_amount, 0) or -get(cfg.def_amount, 0)
        elseif dy == "Spin" then yaw = (g_tick() * 20) % 360 elseif dy == "Static" then yaw = get(cfg.def_amount, 0) end
        local dp = get(cfg.def_pitch)
        if dp == "Up" then ovr(ref.AA.pitch[1], "Up") elseif dp == "Down" then ovr(ref.AA.pitch[1], "Down") elseif dp == "Zero" then ovr(ref.AA.pitch[1], "Off") elseif dp == "Random" then ovr(ref.AA.pitch[1], "Custom"); ovr(ref.AA.pitch[2], m_random(-89, 89)) end
    else
        local pm = get(cfg.pitch)
        if pm == "Random" then ovr(ref.AA.pitch[1], "Custom"); ovr(ref.AA.pitch[2], m_random(-89, 89))
        elseif pm ~= "Off" then ovr(ref.AA.pitch[1], pm) else ovr(ref.AA.pitch[1], "Off") end
    end
    if yaw_direction ~= 0 then yaw = get(aa_misc.tweaks, {}) and contains(get(aa_misc.tweaks, {}), "Static on Manual") and yaw_direction or norm(yaw + yaw_direction); ovr(ref.AA.yawbase, "Local View") else ovr(ref.AA.yawbase, get(cfg.yawbase)) end
    ovr(ref.AA.yaw[1], "180"); ovr(ref.AA.yaw[2], norm(yaw)); ovr(ref.AA.jitter[1], "Off"); ovr(ref.AA.jitter[2], 0)
    if not cmd.allow_send_packet and get(cfg.desync) ~= "Off" and not in_def then
        yaw = mg.declaredyaw
        aam.desyncswitch = not aam.desyncswitch
        local side = get(cfg.desync) == "Static" and (get(aa_misc.desync_inverter) and 1 or -1) or (aam.desyncswitch and 1 or -1)
        ovr(ref.AA.yaw[2], norm(yaw + get(cfg.desync_amount, 60) * side))
    end
    if get(cfg.bodyyaw, false) then
        ovr(ref.AA.bodyyaw[1], get(cfg.body_jitter, false) and "Static" or "Opposite")
        if get(cfg.body_jitter, false) then ovr(ref.AA.bodyyaw[2], aam.switch and -91 or 91) end
    else ovr(ref.AA.bodyyaw[1], "Off"); ovr(ref.AA.bodyyaw[2], 0) end
    if cmd.allow_send_packet then
        aam.switch = not aam.switch
        if not contains(get(aa_misc.tweaks, {}), "Disable Roll on Auto Peek") or not (get(ref.autopeek[1]) and get(ref.autopeek[2])) then cmd.roll = get(cfg.roll, 0) end
        mg.declaredyaw = yaw
    else cmd.roll = 0; mg.fakeyaw = yaw end
    if contains(get(aa_misc.tweaks, {}), "Micro Movement") and mg.lp.speedxy < 2 and cmd.sidemove == 0 and cmd.forwardmove == 0 then
        aam.microtick = aam.microtick + 1; aam.micro = not aam.micro
        cmd.sidemove = (aam.micro and 1 or -1) * (mg.lp.duck and 2 or 1.1) * (1 + (aam.microtick % 7) * 0.02)
    end
    if get(aa_misc.leg_breaker, false) then ovr(ref.leg, cmd.allow_send_packet and "Always slide" or "Never slide") end
end

local function update_exploit()
    mg.exploit = ""
    if get(ref.hideshots[1]) and get(ref.hideshots[2]) then mg.exploit = "HS" end
    if get(ref.doubletap[1]) and get(ref.doubletap[2]) then mg.exploit = "DT" end
end

local function auto_hideshots(cmd)
    local lp = e_local(); if not lp or not e_alive(lp) then return end
    local wep = e_weapon(lp); if not wep then return end
    local wn = e_class(wep)
    local disabled = (wn == "CWeaponSSG08" and contains(get(rage.auto_hs_wep, {}), "Scout")) or (wn == "CWeaponAWP" and contains(get(rage.auto_hs_wep, {}), "AWP")) or ((wn == "CWeaponSCAR20" or wn == "CWeaponG3SG1") and contains(get(rage.auto_hs_wep, {}), "Auto")) or (wn == "CDEagle" and contains(get(rage.auto_hs_wep, {}), "Deagle & R8"))
    if not get(rage.auto_hs, false) or disabled then return end
    local st = player_state(cmd)
    local states = get(rage.auto_hs_state, {})
    local allowed = contains(states, st) or (st == "Ducking" and contains(states, "Ducking"))
    if allowed then ovr(ref.hideshots[1], true); ovr(ref.hideshots[2], true); ovr(ref.doubletap[1], false) end
end

local function dt_guard()
    if not get(rage.dt_recharge, false) or not get(ref.doubletap[2]) or charged() then return end
    local d = depth()
    if d >= 2 then ovr(ref.hitchance, clamp((get(ref.hitchance, 0) or 0) + d * 3, 0, 100)) end
end

local HS = {
    PROFILE = {
        AWP = {mp = 60, hc = 60, sf = 0.25, air_hc = 48, dmg = 100},
        ["SSG 08"] = {mp = 82, hc = 56, sf = 0.30, air_hc = 50, dmg = 100},
        ["G3SG1 / SCAR-20"] = {mp = 48, hc = 38, sf = 0.40, air_hc = 40},
        ["Desert Eagle"] = {mp = 75, hc = 50, sf = 0.35, air_hc = 45},
        ["R8 Revolver"] = {mp = 55, hc = 62, sf = 0.30, air_hc = 48},
        Rifle = {mp = 70, hc = 52, sf = 0.55, air_hc = 45}, SMG = {mp = 85, hc = 45, sf = 0.80},
        Shotgun = {mp = 100, hc = 40, sf = 1.00}, ["Machine gun"] = {mp = 85, hc = 48, sf = 0.75},
        Pistol = {mp = 90, hc = 60, sf = 0.60, air_hc = 52}, Zeus = {mp = 100, hc = 30, sf = 1.00}, Global = {mp = 70, hc = 55, sf = 0.55, air_hc = 48},
    },
    bk = {},
}
local WTYPE_CLASS = {CWeaponAWP = "AWP", CWeaponSSG08 = "SSG 08", CWeaponSCAR20 = "G3SG1 / SCAR-20", CWeaponG3SG1 = "G3SG1 / SCAR-20", CWeaponTaser = "Zeus", CDEagle = "Desert Eagle"}
local function weapon_type(wep)
    if not wep then return "Global" end
    local cn = e_class(wep)
    if cn == "CDEagle" and e_prop(wep, "m_iItemDefinitionIndex") == 64 then return "R8 Revolver" end
    return WTYPE_CLASS[cn] or "Global"
end
local function hs_restore()
    if not ref.wtype then return end
    local prev = get(ref.wtype)
    for key, pack in pairs(HS.bk) do
        local r = key == "mp" and ref.mpscale or key == "hc" and ref.hitchance or key == "dmg" and ref.mindmg or ref.dthc
        if r then for w, v in pairs(pack) do set(ref.wtype, w); set(r, v); pack[w] = nil end end
    end
    set(ref.wtype, prev)
end
local function hs_set(key, r, w, v)
    if not r or not ref.wtype then return end
    HS.bk[key] = HS.bk[key] or {}
    if HS.bk[key][w] == nil then HS.bk[key][w] = get(r) end
    local prev = get(ref.wtype); set(ref.wtype, w); set(r, v); set(ref.wtype, prev)
end
local function spread_floor(dist, speed, air, sf, lethal)
    if not get(rage.spread, true) then return 0 end
    local f = (36 + clamp(dist / 3000, 0, 1) * 38 + clamp(speed / 250, 0, 1) * 22) * (0.80 + sf * 0.60)
    if air then f = f + 18 end
    if lethal then f = f * 0.75 end
    return clamp(f * get(rage.spread_strength, 100) * 0.01, 0, 88)
end
local function adaptive_hitscale()
    local me = e_local(); if not me or not e_alive(me) then hs_restore(); return end
    local w = weapon_type(e_weapon(me))
    local prof = HS.PROFILE[w] or HS.PROFILE.Global
    if not get(rage.hs, false) and not get(rage.dthc, false) then hs_restore(); return end
    local mp, hc, dist = prof.mp, prof.hc, 0
    local tgt = c_threat()
    local pd, h, pr
    if tgt and e_alive(tgt) then
        local e = ents[tgt]; pd, h, pr = e and e.p, e and e.h, e and e.pr
        local ex, ey, ez = c_eye(); local tx, ty, tz = pd and pd.prx ~= 0 and pd.prx or nil, pd and pd.pry, pd and pd.prz
        if not tx then tx, ty, tz = e_origin(tgt) end
        if ex and tx then local dx, dy, dz = tx - ex, ty - ey, tz - ez; dist = m_sqrt(dx * dx + dy * dy + dz * dz) end
    end
    local direct = pd and (pd.hasanim or pd.pbody_ok)
    local conf = h and h.cf or 0
    if pd and (pd.def or pd.ovalid) then mp = mp - 15; hc = hc - 8
    elseif direct and pr and pr.r and conf > 40 then mp = mp - 12; hc = hc - 7
    elseif pd and pd.swd then mp = mp + 20; hc = hc + 12 end
    local air = b_band(e_prop(me, "m_fFlags") or 0, CY.FL_GROUND) == 0
    if air then hc = prof.air_hc or (hc + 15) end
    local hp = tgt and e_prop(tgt, "m_iHealth") or 100
    local lethal = prof.dmg ~= nil or (hp > 0 and hp <= 40)
    hc = m_max(hc + clamp(dist / 3000, 0, 1) * 18, spread_floor(dist, mg.lp.speedxy, air, prof.sf, lethal))
    if not charged() then hc = hc + m_min(depth(), 14) * 2 end
    if get(rage.hs, false) then hs_set("mp", ref.mpscale, w, clamp(m_floor(mp), 24, 100)); hs_set("hc", ref.hitchance, w, clamp(m_floor(hc), 0, 100)) end
    if get(rage.hs_dmg, false) and not get(ref.mindmg_override[1], false) and lethal then hs_set("dmg", ref.mindmg, w, clamp(m_min(prof.dmg or hp, hp), 1, 100)) end
    if get(rage.dthc, false) and get(ref.doubletap[2], false) and ref.dthc then hs_set("dthc", ref.dthc, w, clamp(m_floor((mg.indefensive and get(rage.dthc_def, 55) or get(rage.dthc_off, 30)) + (charged() and 0 or depth() * 4)), 0, 100)) end
end

local function break_anims()
    if not get(aa_misc.tweak_aa, false) then return end
    local me = e_local(); if not me or not e_alive(me) then return end
    local opts = get(aa_misc.tweak_opts, {})
    local vx, vy = e_prop(me, "m_vecVelocity[0]") or 0, e_prop(me, "m_vecVelocity[1]") or 0
    local speed = m_sqrt(vx * vx + vy * vy)
    if contains(opts, "Extreme body lean") and speed >= 3 then
        local w = get(aa_misc.tweak_lean, 100) * 0.01
        if contains(opts, "Lean jitter") then w = w * ((g_tick() % 4) < 2 and 1 or -0.6) end
        local l12 = layerbase(me, 12); if l12 then pcall(ALFS, l12, AL.WEIGHT, w) end
    end
    if contains(opts, "Fake walk") then local l12, l6 = layerbase(me, 12), layerbase(me, 6); if l12 then pcall(ALFS, l12, AL.WEIGHT, 0) end; if l6 then pcall(ALFS, l6, AL.WEIGHT, 0) end end
    if contains(opts, "Air walk") then local l6 = layerbase(me, 6); if l6 then pcall(ALFS, l6, AL.WEIGHT, 1) end end
    if contains(opts, "Fake flash") then local l9 = layerbase(me, 9); if l9 then pcall(ALIS, l9, AL.SEQUENCE, 224); pcall(ALFS, l9, AL.WEIGHT, 1) end end
    if contains(opts, "Moonwalk") then entity.set_prop(me, "m_flPoseParameter", 0, PZ.MOVE_YAW) end
    if contains(opts, "Smoothing") then entity.set_prop(me, "m_flPoseParameter", 0, PZ.LEAN_YAW) end
    if contains(opts, "Fallen legs") then entity.set_prop(me, "m_flPoseParameter", 1, PZ.JUMP_FALL) end
    if contains(opts, "Slide") then entity.set_prop(me, "m_flPoseParameter", 1, PZ.STRAFE_YAW) end
    if contains(opts, "Fake duck") then entity.set_prop(me, "m_flPoseParameter", 1, PZ.STAND) end
    if contains(opts, "Break move yaw") then local ph = (g_tick() % 2 == 0) and 0 or 1; entity.set_prop(me, "m_flPoseParameter", ph, PZ.STRAFE_YAW); entity.set_prop(me, "m_flPoseParameter", 1 - ph, PZ.MOVE_YAW) end
end

local shots, stats = {}, {total = 0, reason = {}, state = {}, stage = {}, src = {}}
local hb_names = {[0] = "generic", "head", "chest", "stomach", "left arm", "right arm", "left leg", "right leg", "neck", "?", "gear"}
local function inc(t, k) k = k or "?"; t[k] = (t[k] or 0) + 1 end
local function snapshot(ent)
    local s, e = {}, ents[ent]
    if not e then return s end
    local v, p, pr, h = e.v, e.p, e.pr, e.h
    if v then s.r_yaw = v.y; s.r_side = v.s; s.r_mag = v.mag; s.r_bidx = v.bi; s.r_src = v.src; s.r_skipped = v.skipped; s.r_onshot = v.onshot end
    if p then s.p_state = p.st; s.p_eye = p.aw; s.p_desync = p.ds; s.p_anim = p.hasanim; s.p_choke = p.chk; s.p_jit = p.jit; s.p_maxds = p.maxdes; s.p_pose = p.pose; s.p_pbodyok = p.pbody_ok end
    if pr then s.r_resolved = pr.r; s.r_stage = pr.s end
    if h then s.r_conf = h.cf end
    return s
end
local function dump_stats()
    client.color_log(255, 255, 255, s_format("[CY-STATS] %d misses this session", stats.total))
    local function line(name, t)
        local p = {}; for k, v in pairs(t) do p[#p + 1] = s_format("%s=%d", tostring(k), v) end
        client.color_log(180, 220, 255, "  " .. name .. ": " .. table.concat(p, "  "))
    end
    line("reason", stats.reason); line("state", stats.state); line("stage", stats.stage); line("source", stats.src)
end

client.set_event_callback("run_command", function(cmd)
    mg.tb.cmd = cmd.command_number
    local held = get(utils.miss_dump)
    if held and not stats.held then dump_stats() end
    stats.held = held
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
    restore()
    local me = e_local(); mg.lp.id = me; if not me then return end
    mg.threat = c_threat()
    local vx, vy, vz = e_prop(me, "m_vecVelocity")
    vx, vy, vz = vx or 0, vy or 0, vz or 0
    mg.lp.speedxy, mg.lp.speedz = m_sqrt(vx * vx + vy * vy), vz
    mg.lp.duck = e_prop(me, "m_bDucked") == 1
    mg.currentloc = vector(e_origin(me)); mg.lp.origin = mg.currentloc
    if mg.shottimer > 0 then mg.shottimer = mg.shottimer - 1 end
    local w = e_weapon(me); local wn = e_class(w)
    mg.weaponswitch = wn ~= mg.weaponname; mg.weaponid = w; mg.weaponname = wn
    if cmd.chokedcommands == 0 then mg.fl_phase = (mg.fl_phase + 1) % 6 end
    mg.hittable_any = false
    for _, en in ipairs(e_players(true)) do local e = ents[en]; if e and e.p and e.p.hittable then mg.hittable_any = true; break end end
    update_exploit()
    setup_aa(cmd)
    auto_hideshots(cmd)
    if get(rage.hideshot_fix, false) and get(ref.hideshots[1]) and get(ref.hideshots[2]) then ovr(ref.FL.enabled[1], false) end
    dt_guard()
    adaptive_hitscale()
    if get(rage.fix_autopeek, false) and get(ref.autopeek[1]) and get(ref.autopeek[2]) then mg.autopeekfix = mg.autopeekfix - 1; if mg.autopeekfix > 0 then cmd.sidemove = 0; cmd.forwardmove = 0 end else mg.autopeekfix = 0 end
    if get(rage.jump_scout, false) and mg.lp.speedz ~= 0 and mg.lp.speedz < 50 and mg.lp.speedz > -10 and mg.weaponname == "CWeaponSSG08" and mg.shottimer <= 0 then cmd.in_speed = 1; ovr(ref.hitchance, get(rage.jump_hc, 40)) end
    if get(utils.fast_ladder, false) and e_prop(me, "m_MoveType") == 9 then cmd.pitch = 89 end
    mg.shotbool = false
end)

client.set_event_callback("net_update_end", function()
    if not get(rage.resolver, true) then return end
    local en = e_players(true)
    for i = 1, #en do resolve(en[i]) end
end)

client.set_event_callback("pre_render", break_anims)

client.set_event_callback("paint", function()
    if get(visuals.watermark, false) then
        local sx, sy = client.screen_size()
        renderer.text(sx - 12, 12, 250, 200, 140, 255, "r", 0, lua_name .. " " .. version)
    end
    local me = e_local()
    if not me or not e_alive(me) then return end
    local sx, sy = client.screen_size(); sx, sy = sx / 2, sy / 2
    if get(visuals.indicators, false) then
        renderer.text(sx, sy + 24, 250, 200, 140, 255, "c-", 0, "COCOYAW")
        renderer.text(sx, sy + 34, mg.indefensive and 80 or 255, 255, mg.indefensive and 80 or 255, 255, "c-", 0, mg.indefensive and "DEFENSIVE" or mg.state)
    end
    if get(visuals.arrows, false) then
        renderer.text(sx - 60, sy, yaw_direction == -90 and 250 or 60, 200, 140, yaw_direction == -90 and 255 or 100, "c", 0, "<")
        renderer.text(sx + 60, sy, yaw_direction == 90 and 250 or 60, 200, 140, yaw_direction == 90 and 255 or 100, "c", 0, ">")
    end
    if get(visuals.damage, false) and get(ref.mindmg_override[1]) then renderer.text(sx + 10, sy - 10, 255, 255, 255, 255, "c-", 0, "DMG") end
    if get(visuals.defensive, false) and depth() > 0 then renderer.indicator(250, 200, 140, 255, "SAFE ", depth()) end
    if get(utils.thirdperson, false) then cvar.cam_idealdist:set_int(get(utils.thirdperson_dist, 150)) end
    if get(utils.aspect, false) then cvar.r_aspectratio:set_float(get(utils.aspect_value, 0) * 0.01) else cvar.r_aspectratio:set_float(0) end
end)

client.set_event_callback("round_prestart", function()
    if get(utils.buybot, false) then
        local cmd = "buy " .. get(utils.primary, " ") .. "; buy " .. get(utils.pistol, " ") .. "; "
        for _, v in ipairs(get(utils.nade, {})) do cmd = cmd .. "buy " .. v .. "; " end
        for _, v in ipairs(get(utils.extra, {})) do cmd = cmd .. "buy " .. v .. "; " end
        client.exec(cmd)
    end
    clear_ents(); tb_reset(); restore()
end)

client.set_event_callback("aim_fire", function(s)
    local r = {target = s.target, name = entity.get_player_name(s.target), bt = s.backtrack, dmg = s.damage, aimed = hb_names[s.hitgroup] or "?", tp = s.teleported, snap = s.target and snapshot(s.target)}
    shots[s.id] = r
    if get(ref.autopeek[1]) and get(ref.autopeek[2]) then mg.autopeekfix = 30 end
    mg.shottimer = 10; mg.shotbool = true
end)

client.set_event_callback("aim_hit", function(s)
    local r = shots[s.id]
    if r and get(utils.logs, false) and contains(get(utils.log_types, {}), "Hit") then
        log_segments({{color(0, 255, 0), "Hit "}, {color(250, 200, 140), entity.get_player_name(s.target)}, {color(220), "'s " .. (hb_names[s.hitgroup] or "?") .. " for " .. s.damage}})
    end
    shots[s.id] = nil
    if get(rage.resolver, true) and s.target then learn(s.target, true, s.hitgroup == 1, nil) end
end)

client.set_event_callback("aim_miss", function(s)
    local r = shots[s.id]
    if r and get(utils.logs, false) and contains(get(utils.log_types, {}), "Miss") then
        log_segments({{color(255, 70, 70), "Missed "}, {color(250, 200, 140), r.name or "?"}, {color(220), "'s " .. (r.aimed or "?") .. " due to " .. (s.reason or "?")}})
    end
    if r and r.snap and get(utils.miss_logs, false) then
        local n = r.snap
        client.color_log(255, 90, 90, s_format("[CY-MISS] %s | %s | src=%s yaw=%.1f mag=%.1f choke=%d", r.name or "?", s.reason or "?", n.r_src or "?", n.r_yaw or 0, n.r_mag or 0, n.p_choke or 0))
        stats.total = stats.total + 1; inc(stats.reason, s.reason or "?"); inc(stats.state, n.p_state and CY.SNAME[n.p_state] or "?"); inc(stats.stage, n.r_bidx or 0); inc(stats.src, n.r_src or "?")
    end
    shots[s.id] = nil
    if get(rage.resolver, true) and s.target then learn(s.target, false, false, s.reason) end
end)

client.set_event_callback("bullet_impact", function(ev)
    if not get(rage.resolver, true) then return end
    local me = client.userid_to_entindex(ev.userid)
    if not me or me ~= e_local() then return end
    local mx, my, mz = e_origin(me); if not mx then return end
    local dx, dy, dz = ev.x - mx, ev.y - my, ev.z - mz
    local mag = m_sqrt(dx * dx + dy * dy + dz * dz); if mag < 1 then return end
    dx, dy, dz = dx / mag, dy / mag, dz / mag
    local best_ent, best_err = nil, 1e9
    for _, en in ipairs(e_players(true)) do
        if not e_dormant(en) then
            local hx, hy, hz = e_hitbox(en, 0)
            if hx then
                local vx, vy, vz = hx - mx, hy - my, hz - mz
                local t = vx * dx + vy * dy + vz * dz
                if t > 0 then
                    local ex, ey, ez = mx + dx * t - hx, my + dy * t - hy, mz + dz * t - hz
                    local err = m_sqrt(ex * ex + ey * ey + ez * ez)
                    if err < best_err then best_ent, best_err = en, err end
                end
            end
        end
    end
    if best_ent and best_err > 8 then learn(best_ent, false, false, "?") end
end)

client.set_event_callback("player_death", function(ev)
    local ent = ev and ev.userid and client.userid_to_entindex(ev.userid)
    if ent then clear_ent(ent) end
    restore()
    if get(utils.trashtalk, false) and ev and client.userid_to_entindex(ev.attacker) == e_local() and client.userid_to_entindex(ev.userid) ~= e_local() then
        client.delay_call(0.2, client.exec, "say cocoyaw on top")
    end
end)

for _, ev in ipairs({"cs_game_disconnected", "client_disconnect", "game_newmap", "cs_match_end_restart"}) do
    client.set_event_callback(ev, function() clear_ents(); tb_reset(); restore(); hs_restore() end)
end

client.set_event_callback("shutdown", function()
    restore(); hs_restore(); clear_ents()
    set(ref.player_reset, true)
    cvar.r_aspectratio:set_float(0)
    cvar.cam_idealdist:set_int(150)
    client.set_clan_tag("")
end)

client.color_log(250, 200, 140, "[CocoYaw v5] Fixed Lua API build online - new UI, resolver, spread guard, tickbase guard.")
