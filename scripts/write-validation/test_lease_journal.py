"""Crash/fault fixtures use empty Python children and temporary lease files only."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from isolation_resources import IsolationLease
import prepare_usb_target as prep
from usb_target import TargetError

MODULES = str(Path(__file__).resolve().parent)


class LeaseJournalChecks(unittest.TestCase):
    def reopen(self, path):
        return subprocess.run([sys.executable, '-c',
            'import os,sys; sys.path.insert(0,sys.argv[2]); from isolation_resources import IsolationLease; '
            'lease=IsolationLease(sys.argv[1],owner_uid=os.getuid()); lease.__enter__(); lease.__exit__()',
            str(path), MODULES], capture_output=True)

    def test_crash_after_child_exit_before_verified_postcondition_blocks_next_process(self):
        with tempfile.TemporaryDirectory() as folder:
            lease = Path(folder) / 'lease'
            child = subprocess.run([sys.executable, '-c',
                'import os,sys; sys.path.insert(0,sys.argv[2]); from prepare_usb_target import PreparationOwner; '
                'owner=PreparationOwner(sys.argv[1],owner_uid=os.getuid()); owner.__enter__(); '
                'owner.mutate([sys.executable,"-c","pass"],before=lambda:None,after=lambda:os._exit(41))',
                str(lease), MODULES], capture_output=True)
            self.assertEqual(child.returncode, 41)
            self.assertNotEqual(self.reopen(lease).returncode, 0,
                                'PID gone and flock free do not prove external-system quiescence')

    def test_pending_is_synced_before_popen_and_completed_allows_reentry(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'lease'
            popen = subprocess.Popen
            def checked(*args, **values):
                records = path.read_bytes().splitlines()
                self.assertTrue(records, 'pending must be durable before child startup')
                self.assertEqual(json.loads(records[-1])['state'], 'pending')
                return popen(*args, **values)
            with prep.PreparationOwner(path, owner_uid=os.getuid()) as owner:
                with patch('prepare_usb_target.subprocess.Popen', side_effect=checked):
                    owner.mutate([sys.executable, '-c', 'pass'], before=lambda: None, after=lambda: None)
            self.assertEqual(json.loads(path.read_bytes().splitlines()[-1])['state'], 'completed')
            self.assertEqual(self.reopen(path).returncode, 0)

    def test_truncated_corrupt_unknown_or_empty_after_history_are_rejected(self):
        for corruption in ('truncated', 'corrupt', 'unknown', 'empty'):
            with self.subTest(corruption=corruption), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / 'lease'
                with prep.PreparationOwner(path, owner_uid=os.getuid()) as owner:
                    owner.mutate([sys.executable, '-c', 'pass'], before=lambda: None, after=lambda: None)
                data = path.read_bytes()
                if corruption == 'truncated': data = data[:-1]
                elif corruption == 'corrupt': data = b'{"schema":1, nope}\n'
                elif corruption == 'unknown': data = data.replace(b'completed', b'unknownxx')
                else: data = b''
                path.write_bytes(data)
                self.assertNotEqual(self.reopen(path).returncode, 0, corruption)

    def test_failed_pending_fsync_prevents_any_child_start(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'lease'
            with prep.PreparationOwner(path, owner_uid=os.getuid()) as owner:
                with patch('isolation_resources.os.fsync', side_effect=OSError('fixture sync failed')), \
                     patch('prepare_usb_target.subprocess.Popen', wraps=subprocess.Popen) as popen:
                    with self.assertRaises(OSError):
                        owner.mutate([sys.executable, '-c', 'pass'], before=lambda: None, after=lambda: None)
                    popen.assert_not_called()
            self.assertNotEqual(self.reopen(path).returncode, 0)

    def test_journal_is_append_only_and_pending_without_child_blocks_reentry(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'lease'
            self.assertTrue(hasattr(IsolationLease, 'begin'), 'shared lease needs a persistent mutation boundary')
            with IsolationLease(path, owner_uid=os.getuid()) as lease:
                lease.begin('usbExperiment')
                original = path.read_bytes()
                lease.record_child(os.getpid())
                self.assertTrue(path.read_bytes().startswith(original))
            self.assertNotEqual(self.reopen(path).returncode, 0)

    def test_usb_experiment_never_completes_while_driver_handle_is_retained(self):
        import usb_lab
        from types import SimpleNamespace
        from unittest.mock import MagicMock
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'lease'
            lab = MagicMock()
            lab.process, lab.pending_mutation = object(), None
            with patch('usb_lab.sys.argv', ['usb_lab.py', '--run']), \
                 patch('usb_lab.private_target', return_value={}), \
                 patch('usb_lab.stable_snapshot', return_value={'node': '/fixture'}), \
                 patch('usb_lab.block_device_info'), patch('usb_lab.dependencies'), \
                 patch('usb_lab.run_preflight'), patch('usb_lab.os.geteuid', return_value=0), \
                 patch('usb_lab.signal.signal'), patch('usb_lab.emit'), \
                 patch('usb_lab.IsolationLease', side_effect=lambda *_: IsolationLease(path, owner_uid=os.getuid())), \
                 patch('usb_lab.USBLab', return_value=lab), patch('usb_lab.complete_cycle'):
                code = usb_lab.main()
            self.assertEqual(code, 1, 'a retained driver cannot establish experiment idle')
            self.assertNotEqual(self.reopen(path).returncode, 0)

    def test_usb_experiment_completes_only_after_fresh_idle_guard(self):
        import usb_lab
        from unittest.mock import MagicMock
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'lease'; order = []
            lab = MagicMock()
            lab.process, lab.pending_mutation = None, None
            lab.guard.side_effect = lambda state: order.append(state)
            def cycle(_lab):
                self.assertEqual(json.loads(path.read_bytes().splitlines()[-1])['state'], 'pending')
                order.append('cycle')
            with patch('usb_lab.sys.argv', ['usb_lab.py', '--run']), \
                 patch('usb_lab.private_target', return_value={}), \
                 patch('usb_lab.stable_snapshot', return_value={'node': '/fixture'}), \
                 patch('usb_lab.block_device_info'), patch('usb_lab.dependencies'), \
                 patch('usb_lab.run_preflight'), patch('usb_lab.os.geteuid', return_value=0), \
                 patch('usb_lab.signal.signal'), patch('usb_lab.emit'), \
                 patch('usb_lab.IsolationLease', side_effect=lambda *_: IsolationLease(path, owner_uid=os.getuid())), \
                 patch('usb_lab.USBLab', return_value=lab), patch('usb_lab.complete_cycle', side_effect=cycle):
                code = usb_lab.main()
            self.assertEqual(code, 0)
            self.assertEqual(order, ['cycle', 'unmounted'])
            self.assertEqual(self.reopen(path).returncode, 0)

    def test_short_journal_read_cannot_hide_a_later_pending_record(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'lease'
            with prep.PreparationOwner(path, owner_uid=os.getuid()) as owner:
                owner.mutate([sys.executable, '-c', 'pass'], before=lambda: None, after=lambda: None)
            completed_prefix = path.read_bytes()
            with IsolationLease(path, owner_uid=os.getuid()) as lease:
                lease.begin('usbExperiment')
            with patch('isolation_resources.os.pread', return_value=completed_prefix):
                with self.assertRaisesRegex(TargetError, 'leaseJournalIncompleteRead'):
                    with IsolationLease(path, owner_uid=os.getuid()): pass

    def test_existing_empty_lease_without_history_is_unknown_not_legacy_safe(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'lease'
            path.write_bytes(b''); path.chmod(0o600)
            with self.assertRaisesRegex(TargetError, 'existingEmptyLeaseUnverified'):
                with IsolationLease(path, owner_uid=os.getuid()): pass
            self.assertEqual(path.read_bytes(), b'')
            self.assertFalse(Path(str(path) + '.journal-started').exists())
