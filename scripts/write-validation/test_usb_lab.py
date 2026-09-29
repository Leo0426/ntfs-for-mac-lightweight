import unittest
import subprocess
import signal
import sys
from pathlib import Path
from unittest.mock import patch

import os
import tempfile
from usb_lab import (complete_cycle, wait_for_mutation, USBLab, defer_interrupts, verify_fskit_binding,
                     fresh_mountpoint, remove_stale_mountpoint)
from usb_target import TargetError


class FakeLab:
    def __init__(self, failure=None):
        self.events = []
        self.failure = failure

    def step(self, name):
        self.events.append(name)
        if self.failure == name:
            raise TargetError('changedTargetOrFailedReadback')

    def unmount_native(self): self.step('unmountNative')
    def mount(self): self.step('mount')
    def check_cleanup(self): self.step('checkCleanup')
    def prepare(self): self.step('prepare')
    def unmount(self): self.step('unmount')
    def verify(self): self.step('verify')
    def finish(self): self.step('finish')


class FSKitBindingChecks(unittest.TestCase):
    def setUp(self):
        self.facts = {'DeviceNode': '/dev/disk9', 'WholeDisk': True, 'VirtualOrPhysical': 'Virtual',
                      'BusProtocol': 'Disk Image', 'TotalSize': 4096}
        self.plist = self.enterContext(patch('usb_lab.plist', side_effect=lambda _: dict(self.facts)))
        self.held = subprocess.CompletedProcess([], 0, b'p4242\nf3\nn/dev/disk6s2\n', b'')
        self.lsof = self.enterContext(patch('usb_lab.subprocess.run', side_effect=lambda *a, **k: self.held))
        self.process = type('P', (), {'pid': 4242})()

    def test_accepts_virtual_source_when_owned_driver_holds_the_partition(self):
        verify_fskit_binding(self.process, '/dev/disk6s2', '/dev/disk9')
        args = self.lsof.call_args.args[0]
        self.assertEqual(args, ['/usr/sbin/lsof', '-a', '-p', '4242', '-Fn', '/dev/disk6s2'])

    def test_rejects_physical_or_unexpected_virtual_source(self):
        for key, value in [('VirtualOrPhysical', 'Physical'), ('TotalSize', 8192), ('WholeDisk', False),
                           ('BusProtocol', 'USB'), ('DeviceNode', '/dev/disk10')]:
            with self.subTest(key=key):
                self.facts[key] = value
                with self.assertRaises(TargetError): verify_fskit_binding(self.process, '/dev/disk6s2', '/dev/disk9')
                self.setUp()

    def test_rejects_when_driver_does_not_hold_target_partition(self):
        for held in [subprocess.CompletedProcess([], 1, b'', b''),
                     subprocess.CompletedProcess([], 0, b'p4242\nf3\nn/dev/disk7s2\n', b''),
                     subprocess.CompletedProcess([], 0, b'p999\nf3\nn/dev/disk6s2\n', b''),
                     subprocess.CompletedProcess([], 2, b'p4242\nn/dev/disk6s2\n', b'')]:
            with self.subTest(held=held):
                self.held = held
                with self.assertRaises(TargetError): verify_fskit_binding(self.process, '/dev/disk6s2', '/dev/disk9')


class MountpointChecks(unittest.TestCase):
    # macOS 27 FSKit leaves the empty mountpoint directory after a standard unmount.
    def test_each_mount_gets_a_new_unused_mountpoint(self):
        first, second = fresh_mountpoint(), fresh_mountpoint()
        self.assertNotEqual(first, second)
        self.assertRegex(str(first), r'^/Volumes/NTFSLiteUSB-[0-9a-f]{32}$')
        with patch('usb_lab.os.path.lexists', return_value=True), self.assertRaises(TargetError):
            fresh_mountpoint()

    def test_stale_mountpoint_removal_only_removes_an_empty_directory(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / 'mnt'
            remove_stale_mountpoint(root)
            root.mkdir()
            remove_stale_mountpoint(root)
            self.assertFalse(root.exists())
            root.mkdir()
            (root / 'data').write_bytes(b'x')
            with self.assertRaises(TargetError): remove_stale_mountpoint(root)
            self.assertTrue((root / 'data').exists())
            link = Path(parent) / 'link'
            link.symlink_to(root)
            with self.assertRaises(TargetError): remove_stale_mountpoint(link)
            self.assertTrue(link.is_symlink())


class USBLabSequenceChecks(unittest.TestCase):
    def test_child_can_receive_normal_termination_during_handle_capture(self):
        with defer_interrupts():
            child = subprocess.run([sys.executable, '-I', '-c',
                                    'import signal; print(signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, []))'],
                                   capture_output=True, text=True, timeout=5)
        self.assertEqual(child.returncode, 0)
        self.assertEqual(child.stdout.strip(), 'False')

    def test_interrupt_is_delivered_after_child_handle_capture_region(self):
        reached = False
        with self.assertRaises(InterruptedError):
            with defer_interrupts():
                signal.raise_signal(signal.SIGINT)
                reached = True
        self.assertTrue(reached)

    def test_timeout_waits_for_actual_exit_without_terminating_mutation(self):
        class Process:
            def __init__(self): self.waits = []
            def wait(self, timeout=None):
                self.waits.append(timeout)
                if timeout is not None:
                    raise subprocess.TimeoutExpired('unmount', timeout)
                return 0
        process = Process()
        with patch('usb_lab.emit'):
            self.assertEqual(wait_for_mutation(process), 0)
        self.assertEqual(process.waits, [30, None])

    def test_unknown_mount_state_preserves_driver_and_waits_without_termination(self):
        class Process:
            def __init__(self): self.waited = False
            def poll(self): return None
            def terminate(self): raise AssertionError('must retain the driver for normal unmount')
            def wait(self, timeout=None): self.waited = True; return 0
        lab = USBLab.__new__(USBLab)
        lab.pending_mutation = None
        lab.process = Process()
        lab.root = Path('/Volumes/NTFSLiteFixture')
        with patch('subprocess.run', side_effect=OSError('mount facts unavailable')):
            lab.stop_after_failure()
        self.assertTrue(lab.process.waited)

    def test_failed_fresh_preflight_never_starts_mount_or_file_writes(self):
        lab = FakeLab('unmountNative')
        with self.assertRaises(TargetError): complete_cycle(lab)
        self.assertEqual(lab.events, ['unmountNative'])

    def test_failed_cleanup_stops_before_large_dataset(self):
        lab = FakeLab('checkCleanup')
        with self.assertRaises(TargetError): complete_cycle(lab)
        self.assertNotIn('prepare', lab.events)
        self.assertNotIn('finish', lab.events)

    def test_failed_readback_keeps_failure_without_success_or_automatic_cleanup(self):
        lab = FakeLab('verify')
        with self.assertRaises(TargetError): complete_cycle(lab)
        self.assertNotIn('finish', lab.events)
        self.assertEqual(lab.events[-1], 'verify')

    def test_success_requires_remount_before_verification_and_leaves_volume_unmounted(self):
        lab = FakeLab()
        complete_cycle(lab)
        before_verify = lab.events[:lab.events.index('verify')]
        self.assertEqual(before_verify.count('mount'), 2)
        self.assertIn('unmount', before_verify)
        self.assertEqual(lab.events[-2:], ['unmount', 'finish'])


if __name__ == '__main__': unittest.main()
