import importlib.util
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
        self.assertIn('"CY Hide-Shots fix"', source)
        self.assertIn('"CY on-shot angle capture"', source)
        self.assertIn('p_set(ent, "Force Body Yaw Value"', source)
        self.assertIn('local tabs = {"Home", "Anti-Aims", "Ragebot", "Utils", "Visuals"}', source)


if __name__ == "__main__":
    unittest.main()
