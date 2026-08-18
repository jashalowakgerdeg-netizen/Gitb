import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "fix_cocoyaw_pui", ROOT / "tools" / "fix_cocoyaw_pui.py"
)
fix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fix)


class CocoYawPuiFixTests(unittest.TestCase):
    def test_reference_names_and_menu_hide_are_hardened(self):
        source = """
local WTYPE_CLASS = {}
-- hide GS built-in AA to avoid conflicts
function fn.menu_hide(value)
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
end
local ref = {
    yawbase = libs.pui.reference('AA', 'Anti-aimbot angles', 'Yaw base'),
    pitch = { libs.pui.reference('AA', 'Anti-aimbot angles', 'pitch') },
    bodyyaw = { libs.pui.reference('AA', 'Anti-aimbot angles', 'Body yaw') },
    plist_fbody = libs.pui.reference("Players", "Adjustments", "Force body yaw"),
}
"""
        patched = fix.patch_source(source)

        self.assertIn("function fn.ui_hotkey(item)", patched)
        self.assertIn("fn.ui_visible(ref.pitch[1], value)", patched)
        self.assertIn("Yaw Base", patched)
        self.assertIn("'Pitch'", patched)
        self.assertIn("Body Yaw", patched)
        self.assertIn("Force Body Yaw", patched)
        self.assertFalse(fix.validate(patched))

    def test_multi_value_dependencies_become_predicates(self):
        source = """
foo:depend({antiaims[i].desync_type, 'Jitter', 'Static'})
bar:depend({antiaims[i].def_pitch, 'Switch', '3-Way', '5-Way', 'Vladick', 'Spin'})
baz:depend({luaUi.visuals.watermark_type, 'Modern', 'Minimalistic'})
"""
        patched = fix.patch_source(source)

        self.assertIn("fn.dep_any(antiaims[i].desync_type, 'Jitter', 'Static')", patched)
        self.assertIn("fn.dep_any(antiaims[i].def_pitch, 'Switch', '3-Way', '5-Way', 'Vladick', 'Spin')", patched)
        self.assertIn("fn.dep_any(luaUi.visuals.watermark_type, 'Modern', 'Minimalistic')", patched)
        self.assertFalse(fix.validate(patched))

    def test_hideshots_and_runtime_edge_fixes_are_applied(self):
        source = """
if luaUi.ragebot.hideshot_fix:get() and ref.os.value and ref.os.hotkey:get() then
end
if ref.os and ref.os.hotkey and ref.os.hotkey:get() then mg.exploit = "HS"; mg.DTHS = 1 end
if ref.dt[1]:get_hotkey() then mg.exploit = "DT"; mg.DTHS = mg.DTHS + 1 end
h.g[#h.g+1] = {yaw=rv.y, off=off, st=st, t=now, hs=hs, stg=bidx}
return m_random(mn, mx)
local idx = m_floor(math.fmod((g_tick() + (client.latency(0)/TICK_IV))/22, CT_N+1)+1)
fn.anti_aim_setup(cmd)
    fn.run_direction()
if luaUi.ragebot.auto_hide_shots:get() then fn.auto_osaa(cmd) end
"""
        patched = fix.patch_source(source)

        self.assertIn("fn.ui_enabled(ref.os) and fn.ui_hotkey(ref.os)", patched)
        self.assertIn("fn.ui_hotkey(ref.dt[1])", patched)
        self.assertIn("t=g_realtime()", patched)
        self.assertIn("client.random_float", patched)
        self.assertNotIn("client.latency(0)", patched)
        self.assertIn("fn.run_direction()\n    fn.anti_aim_setup(cmd)", patched)
        self.assertIn("fn.auto_osaa(cmd)", patched)
        self.assertFalse(fix.validate(patched))

    def test_checked_in_lua_avoids_known_pui_port_failures(self):
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")

        self.assertNotIn("gamesense/pui", source)
        self.assertNotIn("ref.os.value", source)
        self.assertNotIn("client.latency(0)", source)
        self.assertNotIn("return d == nil or d >= 0 and 0 or -d", source)
        self.assertIn('local tabs = {"Home", "Anti-Aims", "Ragebot", "Utils", "Visuals"}', source)

    def test_checked_in_lua_parses(self):
        try:
            from luaparser import ast as lua_ast
        except ImportError:
            self.skipTest("luaparser not installed")
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        lua_ast.parse(source)

    def test_no_dead_break_animation_options(self):
        # every string in the break-animations multiselect must be consumed by
        # break_anims via contains(o, "...") - a menu option with no code path
        # is exactly the regression this build was rewritten to remove.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")

        start = source.index('tweak_opts = fn.ms("CY Animation Breaks"')
        end = source.index('"Land pitch break")', start) + len('"Land pitch break"')
        block = source[start:end]
        options = re.findall(r'"([^"]+)"', block)
        options = [o for o in options if o != "CY Animation Breaks"]
        self.assertEqual(len(options), 19)

        consumed = set(re.findall(r'contains\(o, "([^"]+)"\)', source))
        consumed |= set(re.findall(r'fn\.contains\(o, "([^"]+)"\)', source))
        missing = [o for o in options if o not in consumed]
        self.assertEqual(missing, [], f"dead break-animation options: {missing}")

    def test_full_build_includes_ported_systems(self):
        # after namespacing, top-level helpers live under the `fn` table
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        for needle in (
            "function fn.backtrack_record",
            "function fn.backtrack_best",
            "function fn.baim_update",
            "function fn.freestand_enemy",
            "function fn.dt_auto",
            "function fn.dt_feedback",
            "function fn.custom_hitchance",
            "function fn.head_peek_lean",
            "function fn.coco_def_yaw",
            'if mod == "3-Way"',
            'dp == "Vladick"',
            "function fn.collect_state",
            "function fn.console_filter",
            "function fn.apply_view",
        ):
            self.assertIn(needle, source, f"missing ported system: {needle}")

    def test_tab_comboboxes_do_not_leak_across_tabs(self):
        # ui_sub / ui_state are standalone controls (not in ITEMS), so they must
        # be explicitly hidden at the top of refresh_menu or they show on every
        # tab. This is the exact regression reported.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        start = source.index("function fn.refresh_menu()")
        head = source[start:start + 400]
        self.assertIn("fn.vis(ui_sub, false)", head)
        self.assertIn("fn.vis(ui_state, false)", head)

    def test_fake_flash_rebuild(self):
        # writing sequence+weight alone is erased by the next animation update,
        # so the exploit must zero the weight decay and force a rebuild, and it
        # must phase-lock to the fake (choked) side rather than sitting constant.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        self.assertIn("function fn.anim_rebuild(ast)", source)
        self.assertIn("LAST_UPDATE_TIME = 0x06C", source)
        self.assertIn("LAST_UPDATE_FRAME = 0x070", source)
        self.assertIn("WEIGHT_RATE = 0x24", source)
        flash = source[source.index('if fn.contains(o, "Fake flash") then'):]
        flash = flash[:flash.index("fn.anim_rebuild(ast)")]
        self.assertIn("AL.WEIGHT_RATE, 0", flash)
        self.assertIn("mg.last_sent", flash)
        # phase-locked to the real desync side the server is holding
        self.assertIn("fn.pose_body(me)", flash)
        self.assertIn("PZ.LEAN_YAW", flash)
        self.assertIn("PZ.BODY_PITCH", flash)

    def test_fake_flash_server_side_body_yaw(self):
        # the genuinely server-authoritative lever: on the fake packet the body
        # yaw is driven to the engine ceiling on the desync side.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        self.assertIn("mg.flash_active = false", source)
        hook = source[source.index("Fake flash exploit - server-side portion."):]
        hook = hook[:hook.index("-- extended defensive")]
        self.assertIn('fn.ovr(ref.AA.bodyyaw[1], "Static")', hook)
        self.assertIn("fn.ovr(ref.AA.bodyyaw[2], side * 90)", hook)
        self.assertIn("not cmd.allow_send_packet", hook)

    def test_menu_names_formatted_not_raw_cy_prefix(self):
        # display names go through menu_name, which strips "CY ", sentence-cases,
        # and wraps in <--...-->. No control name should reach ui.new_* as a bare
        # "CY ..." literal.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        self.assertIn("local function menu_name(raw)", source)
        self.assertIn('"<--" .. s:sub(1, 1):upper() .. s:sub(2):lower() .. "-->"', source)
        bare = re.findall(r'ui\.new_\w+\(TAB, CONT, "CY ', source)
        self.assertEqual(bare, [], "raw CY-prefixed name passed to ui.new_* without menu_name")

    def test_config_buttons_included_in_items_snapshot(self):
        # config buttons are created after the first ITEMS snapshot; ITEMS must be
        # rebuilt afterwards or they never get hidden and leak onto every tab.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        buttons_at = source.index("m.cfg_buttons = {")
        rebuild_at = source.index("ITEMS = fn.all_items()", buttons_at)
        callback_at = source.index("ipairs(ITEMS) do pcall(ui.set_callback", buttons_at)
        self.assertLess(buttons_at, rebuild_at)
        self.assertLess(rebuild_at, callback_at)

    def test_no_unsafe_floating_tab_overlay(self):
        # a floating overlay drawn outside the menu leaks onto every gamesense
        # tab and can pass clicks through to the game (accidental fire). Tab
        # selection must stay inside the menu via the combobox.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        self.assertNotIn("draw_tab_icons", source)
        self.assertNotIn("renderer.load_svg", source)
        self.assertNotIn("client.key_state", source)
        self.assertIn("fn.vis(ui_tab, true)", source)

    def test_stays_under_luajit_local_limit(self):
        # LuaJIT caps a function scope at 200 locals; the chunk body is one scope.
        source = (ROOT / "cocoyaw.lua").read_text(encoding="utf-8")
        slots = 0
        for line in source.splitlines():
            if line.startswith("local function "):
                slots += 1
            elif line.startswith("local "):
                decl = line[len("local "):].split("=")[0]
                slots += len([x for x in decl.split(",") if x.strip()])
        self.assertLess(slots, 200, f"top-level local slots={slots} exceeds LuaJIT cap")


if __name__ == "__main__":
    unittest.main()
