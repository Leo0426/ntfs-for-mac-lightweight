import errno
import io
import json
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from usb_lab import main


class USBDiagnosticChecks(unittest.TestCase):
    def setUp(self):
        expected = {'mediaName': 'U310', 'physicalBytes': 32212254720, 'partitionBytes': 32000442368}
        self.facts = {'node': '/dev/disk6s2', 'disk': 'disk6', 'writable': False}
        self.enterContext(patch('usb_lab.private_target', return_value=expected))
        self.enterContext(patch('usb_lab.stable_snapshot', return_value=self.facts))
        self.enterContext(patch('usb_lab.block_device_info', return_value=SimpleNamespace(st_rdev=16777242)))
        self.enterContext(patch('usb_lab.dependencies'))
        self.enterContext(patch('usb_lab.os.geteuid', return_value=0))
        self.open = self.enterContext(patch('usb_lab.os.open', return_value=42))
        self.enterContext(patch('usb_lab.os.fstat', return_value=SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600, st_uid=0, st_nlink=1)))
        self.enterContext(patch('usb_lab.fcntl.flock'))
        self.enterContext(patch('usb_lab.os.close'))
        self.enterContext(patch('usb_lab.signal.signal'))
        self.cycle = self.enterContext(patch('usb_lab.complete_cycle'))

    def invoke(self, mode):
        output = io.StringIO()
        with patch('usb_lab.sys.argv', ['usb_lab.py', mode]), patch('usb_lab.sys.stdout', output):
            code = main()
        return code, json.loads(output.getvalue())

    def test_lock_failure_reports_phase_and_errno_without_private_error_text(self):
        self.open.side_effect = OSError(errno.EIO, 'private diagnostic', '/private/secret/path')
        code, report = self.invoke('--run')
        self.assertEqual(code, 1)
        self.assertEqual(report['operation'], 'leaseOpen')
        self.assertEqual(report['errno'], errno.EIO)
        self.assertEqual(report['errnoName'], 'EIO')
        self.assertNotIn('private', json.dumps(report))
        self.assertFalse(report['diskMutationsPerformed'])
        self.cycle.assert_not_called()

    def test_constructor_failure_remains_no_mutation_with_exact_initialization_stage(self):
        with patch('usb_lab.USBLab', side_effect=OSError(errno.EINVAL, 'private text')):
            code, report = self.invoke('--run')
        self.assertEqual(code, 1)
        self.assertEqual(report['operation'], 'initializeExperiment')
        self.assertEqual(report['errnoName'], 'EINVAL')
        self.assertFalse(report['diskMutationsPerformed'])
        self.cycle.assert_not_called()

    def test_read_only_probe_never_creates_lab_or_lease_or_runs_cycle(self):
        with patch('usb_lab.probe_device', return_value=512) as probe, \
             patch('usb_lab.USBLab') as lab:
            code, report = self.invoke('--probe-device')
        self.assertEqual(code, 0)
        self.assertEqual(report['stage'], 'deviceReadVerified')
        self.assertEqual(report['bootBytes'], 512)
        self.assertFalse(report['diskMutationsPerformed'])
        probe.assert_called_once()
        lab.assert_not_called()
        self.open.assert_not_called()
        self.cycle.assert_not_called()


if __name__ == '__main__': unittest.main()
