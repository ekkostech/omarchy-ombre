import importlib.util
import importlib.machinery
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader('sessions', str(Path(__file__).resolve().parents[1] / 'bin/ombre-sessions'))
spec = importlib.util.spec_from_loader(loader.name, loader)
adapter = importlib.util.module_from_spec(spec)
loader.exec_module(adapter)

class SessionsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ombre-session-test-')
        self.env = patch.dict(os.environ, TMUX_TMPDIR=self.temp.name, TMUX='')
        self.env.start()
        self.sock = str(Path(self.temp.name) / f'tmux-{os.getuid()}' / 'omaguake')
        Path(self.sock).parent.mkdir(mode=0o700)
        subprocess.run(['tmux', '-f', '/dev/null', '-S', self.sock, 'new-session', '-d', '-s', 'omaguake_tab_1', 'sleep 120'], check=True)
        adapter.tmux(self.sock, 'split-window', '-d', 'sleep 120', required=True)

    def tearDown(self):
        adapter.tmux(self.sock, 'kill-server')
        self.env.stop()
        self.temp.cleanup()

    def panes(self):
        return adapter.discover()

    def test_identity_labels_and_pane_isolation(self):
        a, b = self.panes()
        self.assertEqual(a['backend'], 'omaguake')
        adapter.action({'op':'label', 'sessionId':a['sessionId'], 'label':'API $(touch nope)'})
        again = self.panes()
        self.assertEqual(again[0]['sessionId'], a['sessionId'])
        self.assertEqual(again[0]['label'], 'API $(touch nope)')
        self.assertEqual(again[1]['label'], '')
        adapter.tmux(self.sock, 'set-option', '-p', '-t', a['pane'], 'window-style', 'fg=green', required=True)
        req = {'op':'style','sessionId':a['sessionId'], 'look':{'kind':'tint','id':'blue'}, 'background':'#102030', 'foreground':'#eeeeee', 'cursor':'#ffffff', 'colors':['#123456']*16,'persist':True}
        adapter.action(req)
        self.assertIn('bg=#102030', adapter.tmux(self.sock, 'show-options', '-pv', '-t', a['pane'], 'window-style'))
        self.assertNotIn('#102030', adapter.tmux(self.sock, 'show-options', '-pv', '-t', b['pane'], 'window-style'))
        self.assertEqual(json.loads(adapter.tmux(self.sock, 'show-options', '-pv', '-t', a['pane'], '@ombre-look')),req['look'])
        self.assertEqual(adapter.tmux(self.sock, 'show-options', '-pv', '-t', a['pane'], 'pane-colours[0]').strip(), '#123456')
        adapter.action({'op':'style','sessionId':a['sessionId'],'look':None,'persist':True})
        self.assertEqual(adapter.tmux(self.sock, 'show-options', '-pv', '-t', a['pane'], 'window-style').strip(), 'fg=green')
        self.assertEqual(adapter.tmux(self.sock, 'show-options', '-pv', '-t', a['pane'], 'pane-colours[0]').strip(), '')

    def test_reused_server_identity_is_rejected(self):
        a = self.panes()[0]
        identity = json.loads(a['sessionId']); identity[2] = '0'
        with self.assertRaisesRegex(ValueError, 'ended'):
            adapter.action({'op':'label','sessionId':json.dumps(identity,separators=(',',':')),'label':'wrong'})

    def test_bad_input_and_detached_switch(self):
        a = self.panes()[0]
        for req in ({'op':'style','background':'red; run-shell whoami','look':{}}, {'op':'label','label':'line\nbreak'}):
            with self.assertRaises(ValueError):
                adapter.action(dict(req, sessionId=a['sessionId']))
        with self.assertRaisesRegex(ValueError, 'detached'):
            adapter.action({'op':'focus','sessionId':a['sessionId']})

if __name__ == '__main__':
    unittest.main()
