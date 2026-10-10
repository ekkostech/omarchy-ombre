import importlib.machinery
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import tomllib
import unittest

HELPER = Path(__file__).resolve().parents[1] / 'bin/ombre-sync-agent-themes'
bridge = importlib.machinery.SourceFileLoader('bridge', str(HELPER)).load_module()

class AgentThemes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.claude = self.root / 'claude'
        self.codex = self.root / 'codex'
        self.claude.mkdir(); self.codex.mkdir()
        self.env = dict(os.environ, CLAUDE_CONFIG_DIR=str(self.claude), CODEX_HOME=str(self.codex), XDG_STATE_HOME=str(self.root / 'state'))
        self.c = self.claude / 'settings.json'
        self.x = self.codex / 'config.toml'
        self.c.write_text(json.dumps({'theme': 'custom:mine', 'permissions': {'allow': ['Read']}, 'env': {'TEST': 'keep'}}))
        self.original = '# Keep comments\nmodel = "example"\n[tui]\n# User theme\ntheme = "solarized-dark"\nnotifications = false\n[projects."/tmp/p"]\ntrust_level = "trusted"\n'
        self.x.write_text(self.original)

    def tearDown(self):
        self.tmp.cleanup()

    def run_action(self, action, success=True):
        p = subprocess.run(['python3', str(HELPER), action], env=self.env, capture_output=True, text=True)
        self.assertEqual(p.returncode, 0 if success else 1, p.stdout + p.stderr)
        return json.loads(p.stdout)

    def test_link_preserves_all_other_settings_and_comments(self):
        before_c = json.loads(self.c.read_text()); before_x = tomllib.loads(self.original)
        result = self.run_action('link')
        self.assertTrue(result['linked'])
        before_c['theme'] = 'custom:ombre'; before_x['tui']['theme'] = 'ombre'
        self.assertEqual(json.loads(self.c.read_text()), before_c)
        self.assertEqual(tomllib.loads(self.x.read_text()), before_x)
        self.assertIn('# User theme', self.x.read_text())
        self.assertIn('# Keep comments', self.x.read_text())
        self.assertEqual(self.c.stat().st_mode & 0o777, 0o600)
        state = (self.root / 'state/ombre/agent-themes/preferences.json').read_text()
        self.assertNotIn('permissions', state)

    def test_repeat_link_and_unlink_restore_prior_themes(self):
        self.run_action('link'); self.run_action('link')
        result = self.run_action('unlink')
        self.assertFalse(result['linked'])
        self.assertFalse(result['canUnlink'])
        self.assertEqual(json.loads(self.c.read_text())['theme'], 'custom:mine')
        self.assertEqual(self.x.read_text(), self.original)

    def test_unlink_preserves_new_user_choices(self):
        self.run_action('link')
        c = json.loads(self.c.read_text()); c['theme'] = 'light'; self.c.write_text(json.dumps(c))
        self.x.write_text(self.x.read_text().replace('"ombre"', '"nord"'))
        self.run_action('unlink')
        self.assertEqual(json.loads(self.c.read_text())['theme'], 'light')
        self.assertEqual(tomllib.loads(self.x.read_text())['tui']['theme'], 'nord')

    def test_missing_configs_and_no_prior_theme(self):
        self.c.unlink(); self.x.unlink()
        self.run_action('link'); self.run_action('unlink')
        self.assertNotIn('theme', json.loads(self.c.read_text()))
        self.assertNotIn('theme', tomllib.loads(self.x.read_text())['tui'])

    def test_invalid_config_is_not_overwritten_and_partial_status_is_reported(self):
        self.x.write_text('invalid [')
        result = self.run_action('link', False)
        self.assertFalse(result['linked']); self.assertTrue(result['claude']['linked'])
        self.assertFalse(result['codex']['linked'])
        self.assertEqual(self.x.read_text(), 'invalid [')
        self.assertFalse((self.codex / 'themes/ombre.tmTheme').exists())

    def test_complex_inline_toml_fails_closed(self):
        self.x.write_text('tui = {theme = "nord", notifications = false}\n')
        before = self.x.read_bytes()
        self.run_action('link', False)
        self.assertEqual(self.x.read_bytes(), before)

    def test_existing_custom_ombre_theme_is_preserved(self):
        p = self.claude / 'themes/ombre.json'; p.parent.mkdir(); p.write_text('{"name":"My own Ombre"}')
        result = self.run_action('link', False)
        self.assertFalse(result['claude']['linked'])
        self.assertEqual(p.read_text(), '{"name":"My own Ombre"}')
        self.assertEqual(json.loads(self.c.read_text())['theme'], 'custom:mine')

    def test_native_themes_use_palette_references_not_fixed_rgb(self):
        self.run_action('link')
        c = json.loads((self.claude / 'themes/ombre.json').read_text())
        self.assertEqual(c['overrides']['text'], 'ansi:whiteBright')
        self.assertEqual(c['overrides']['success'], 'ansi:green')
        self.assertTrue(all(v.startswith('ansi:') for v in c['overrides'].values()))
        x = plistlib.loads((self.codex / 'themes/ombre.tmTheme').read_bytes())
        for item in x['settings']:
            for key, value in item['settings'].items():
                if key != 'fontStyle':
                    self.assertRegex(value, r'^#[0-9a-f]{6}0[01]$')
        diff = next(s for s in x['settings'] if 'markup.inserted' in s.get('scope', ''))
        self.assertEqual(diff['settings'], {'foreground': '#02000000', 'background': '#00000001'})
        # Native theme files stay identical across terminal mood changes: each
        # renderer resolves ANSI slots in its own terminal, never a global RGB.
        before = (self.codex / 'themes/ombre.tmTheme').read_bytes()
        self.run_action('link')
        self.assertEqual(before, (self.codex / 'themes/ombre.tmTheme').read_bytes())

    def test_atomic_write_refuses_concurrent_edit(self):
        p = self.root / 'race'; p.write_bytes(b'new user edit')
        with self.assertRaises(ValueError):
            bridge.atomic(p, b'plugin edit', b'old')
        self.assertEqual(p.read_bytes(), b'new user edit')

    def test_quoted_tui_table(self):
        data = b'["tui"]\n"theme" = "nord"\nnotifications = true\n'
        out = bridge.toml_theme(data, 'ombre')
        self.assertEqual(tomllib.loads(out.decode()), {'tui': {'theme': 'ombre', 'notifications': True}})

if __name__ == '__main__':
    unittest.main()
