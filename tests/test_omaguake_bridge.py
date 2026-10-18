import hashlib
import importlib.machinery
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader=importlib.machinery.SourceFileLoader('bridge',str(Path(__file__).resolve().parents[1]/'bin/ombre-setup-omaguake'))
spec=importlib.util.spec_from_loader(loader.name,loader)
bridge=importlib.util.module_from_spec(spec)
loader.exec_module(bridge)

SOURCE='''  property bool opened: false
      // Terminal Content Area
        layer.enabled: container.cardOpacity < 0.999
          property color bgColor: Color.background
          property real bgOpacity: container.cardOpacity
'''

class BridgeTest(unittest.TestCase):
    def test_install_repeat_undo_and_refuse_modified_source(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(bridge,'BASE',hashlib.sha256(SOURCE.encode()).hexdigest()):
            file=Path(folder)/'Overlay.qml';file.write_text(SOURCE)
            bridge.install(folder)
            patched=file.read_text()
            self.assertIn('Image.PreserveAspectCrop',patched)
            self.assertIn('root.ombreWallpaper.background',patched)
            self.assertIn('root.ombreWallpaper.strength',patched)
            self.assertIn('already',bridge.install(folder))
            file.write_text(patched+'\n// later user edit')
            with self.assertRaises(ValueError):bridge.install(folder,True)
            file.write_text(patched)
            bridge.install(folder,True)
            self.assertEqual(file.read_text(),SOURCE)
            file.write_text(SOURCE+'\n// upstream change')
            with self.assertRaises(ValueError):bridge.install(folder)

if __name__=='__main__':unittest.main()
