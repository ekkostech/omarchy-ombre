import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1] / 'bin/ombre-keep-running'
loader = importlib.machinery.SourceFileLoader('keep_running', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
keep = importlib.util.module_from_spec(spec)
loader.exec_module(keep)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.entry = {'id': 'demo.desktop', 'enabled': True, 'class': ''}
        self.app = {'id': 'demo.desktop', 'name': 'Demo', 'class': 'DemoWindow', 'executable': '/opt/demo'}
        self.started = []

    def step(self, old=None, now=100, windows=None, procs=None, start=None):
        return keep.tick(self.entry, self.app, old or {}, [] if windows is None else windows,
                         procs or set(), now, start or (lambda app: self.started.append(app['id'])))

    def test_existing_window_and_background_process_are_adopted(self):
        for windows, procs in [([{'class': 'demowindow'}], set()), ([], {'/opt/demo'})]:
            self.assertEqual(self.step(windows=windows, procs=procs)['status'], 'Running')
        self.assertEqual(self.started, [])

    def test_launch_once_then_crash_backoff_and_stable_recovery(self):
        state = self.step()
        self.assertEqual(self.started, ['demo.desktop'])
        state = self.step(state, now=103)
        self.assertEqual(len(self.started), 1)
        state = self.step(state, now=104, windows=[{'class':'DemoWindow'}])
        state = self.step(state, now=110)
        self.assertEqual(len(self.started), 1)
        state = self.step(state, now=145)
        self.assertEqual(len(self.started), 2)
        self.assertEqual(state['next_attempt'], 235)
        state = self.step(state, now=150, windows=[{'class':'DemoWindow'}])
        state = self.step(state, now=211, windows=[{'class':'DemoWindow'}])
        self.assertEqual(state['attempts'], 0)
        state = self.step(state, now=212)
        self.assertEqual(len(self.started), 3)
        self.assertEqual(state['next_attempt'], 257)

    def test_failure_survives_worker_restart_and_is_rate_limited(self):
        def fail(app):
            raise OSError('launcher unavailable')
        state = self.step(start=fail)
        self.assertEqual(state['error'], 'launcher unavailable')
        state = self.step(json.loads(json.dumps(state)), now=110)
        self.assertEqual(self.started, [])
        for stamp in range(145, 4000, 700):
            state = self.step(state, now=stamp, start=fail)
            self.assertLessEqual(state['next_attempt'] - stamp, 600)

    def test_attempt_is_recorded_before_launch_for_reload_recovery(self):
        recorded = {}
        def remember(state):
            recorded.update(json.loads(json.dumps(state)))
        def start(app):
            self.assertEqual(recorded['next_attempt'], 145)
            raise OSError('interrupted launcher')
        keep.tick(self.entry, self.app, {}, [], set(), 100, start, remember)
        self.step(recorded, now=101)
        self.assertEqual(self.started, [])

    def test_disabled_missing_app_and_unavailable_desktop_never_launch(self):
        self.entry['enabled'] = False
        self.assertEqual(self.step()['status'], 'Off')
        self.entry['enabled'] = True
        for app, windows in [(None, []), (self.app, None)]:
            result = keep.tick(self.entry, app, {}, windows, set(), 100, lambda _: self.started.append('bad'))
            self.assertNotEqual(result['status'], 'Starting')
        self.assertEqual(self.started, [])

    def test_specific_class_override_does_not_adopt_other_windows(self):
        self.entry['class'] = 'only-this-window'
        self.step(windows=[{'class':'DemoWindow'}], procs={'/opt/demo'})
        self.assertEqual(len(self.started), 1)
        result = self.step(windows=[{'initialClass':'only-this-window'}])
        self.assertEqual(result['status'], 'Running')

    def test_shared_runtime_does_not_match_unrelated_app(self):
        for exe in ('python3', 'python3.14', 'node', 'electron', 'electron42', 'env', 'sh'):
            self.app['executable'] = exe
            self.assertFalse(keep.is_running(self.entry, self.app, [], {exe}))

    def test_bad_compositor_reply_does_not_look_like_all_apps_exited(self):
        with patch.dict(os.environ, HYPRLAND_INSTANCE_SIGNATURE='test'), patch.object(keep.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'offline')):
            self.assertIsNone(keep.desktop_windows())


class SettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, XDG_CONFIG_HOME=self.temp.name, XDG_RUNTIME_DIR=self.temp.name)
        self.env.start()
        self.catalog = patch.object(keep, 'catalog', return_value={'demo.desktop': {'id':'demo.desktop','name':'Demo'}})
        self.catalog.start()

    def tearDown(self):
        self.catalog.stop(); self.env.stop(); self.temp.cleanup()

    def test_selection_roundtrip_disable_remove_and_private_atomic_file(self):
        keep.change({'op':'set','id':'demo.desktop','enabled':True,'class':'Demo'})
        keep.change({'op':'set','id':'demo.desktop','enabled':False})
        row = keep.load_config()['apps'][0]
        self.assertEqual(row, {'id':'demo.desktop','enabled':False,'class':'Demo'})
        self.assertEqual(keep.paths()[0].stat().st_mode & 0o777, 0o600)
        keep.change({'op':'remove','id':'demo.desktop'})
        self.assertEqual(keep.load_config()['apps'], [])

    def test_invalid_ids_uninstalled_apps_and_bad_config_are_not_overwritten(self):
        for ident in ('../../bad.desktop', 'not-installed.desktop', 'demo.desktop\n'):
            with self.assertRaises(ValueError): keep.change({'op':'set','id':ident,'enabled':True})
        path = keep.paths()[0]; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('{bad')
        with self.assertRaises(ValueError): keep.change({'op':'set','id':'demo.desktop','enabled':True})
        self.assertEqual(path.read_text(), '{bad')


class WatcherIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('gio') and shutil.which('sleep'), 'GIO and sleep required')
    def test_real_launch_exit_restart_single_watcher_and_disable(self):
        with tempfile.TemporaryDirectory(prefix='ombre-watch-test-') as directory:
            root = Path(directory)
            apps = root / 'data/applications'; apps.mkdir(parents=True)
            testbin = root / 'bin'; testbin.mkdir()
            exe = testbin / ('ombre-fixture-' + root.name)
            shutil.copy2(shutil.which('sleep'), exe)
            hypr = testbin / 'hyprctl'; hypr.write_text('#!/bin/sh\nprintf "[]\\n"\n'); hypr.chmod(0o700)
            (apps/'fixture.desktop').write_text('[Desktop Entry]\nType=Application\nName=Ombre test fixture\nExec="'+str(exe)+'" 120\nStartupNotify=false\n')
            env = {**os.environ, 'XDG_CONFIG_HOME':str(root/'config'), 'XDG_DATA_HOME':str(root/'data'), 'XDG_DATA_DIRS':str(root/'empty'),
                   'XDG_RUNTIME_DIR':str(root/'runtime'), 'HYPRLAND_INSTANCE_SIGNATURE':'fixture', 'PATH':str(testbin)+os.pathsep+os.environ['PATH']}
            with patch.dict(os.environ, env):
                keep.change({'op':'set','id':'fixture.desktop','enabled':True})
            code = 'import runpy; d=runpy.run_path('+repr(str(HELPER))+'); d["watch"].__globals__.update(GRACE=1,STABLE=2,MAX_DELAY=4); d["watch"]()'
            worker = subprocess.Popen(['python3','-I','-c',code], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            def pids():
                found=[]
                for p in Path('/proc').iterdir():
                    if p.name.isdigit():
                        try:
                            if os.readlink(p/'exe') == str(exe): found.append(int(p.name))
                        except OSError: pass
                return found
            def wait_for(predicate, timeout=14):
                end=time.monotonic()+timeout
                while time.monotonic()<end:
                    if predicate(): return
                    if worker.poll() is not None:
                        self.fail('watcher exited: '+repr(worker.communicate()))
                    time.sleep(.1)
                self.fail('fixture did not reach expected state')
            try:
                wait_for(lambda:len(pids())==1)
                first=pids()[0]
                second=subprocess.run(['python3','-I',str(HELPER),'watch'],env=env,capture_output=True,timeout=5)
                self.assertEqual(second.returncode,0,second.stderr)
                self.assertEqual(pids(),[first])
                os.kill(first,signal.SIGTERM)
                wait_for(lambda:len(pids())==1 and pids()[0]!=first)
                surviving=pids()[0]
                with patch.dict(os.environ, env): keep.change({'op':'set','id':'fixture.desktop','enabled':False})
                status=root/'runtime/ombre/keep-running/status.json'
                wait_for(lambda:status.exists() and json.loads(status.read_text())['apps']['fixture.desktop']['status']=='Off')
                self.assertEqual(pids(),[surviving], 'disable must leave the app running')
                os.kill(surviving,signal.SIGTERM)
                time.sleep(3.2)
                self.assertEqual(pids(),[], 'disabled app was relaunched')
            finally:
                worker.terminate()
                try: worker.communicate(timeout=5)
                except subprocess.TimeoutExpired: worker.kill(); worker.communicate()
                for pid in pids(): os.kill(pid,signal.SIGTERM)
