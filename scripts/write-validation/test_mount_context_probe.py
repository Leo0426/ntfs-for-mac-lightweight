import os
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from mount_context_probe import probe_mount
from usb_target import TargetError


class MountContextChecks(unittest.TestCase):
    def test_existing_fskit_residual_prevents_starting_another_driver(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            image = directory / 'image.ntfs'
            image.write_bytes(b'fixture')
            result = subprocess.CompletedProcess([], 0,
                b'/dev/disk99 on /Volumes/NTFSLiteOld (macfuse, local, fskit)\n', b'')
            with patch('subprocess.run', return_value=result), patch('subprocess.Popen') as start:
                with self.assertRaisesRegex(TargetError, 'existingExperimentMount'):
                    probe_mount(image, directory / 'mount', directory / 'mount.log')
            start.assert_not_called()

    def run_mount_fixture(self, read_only=True, interrupt=False, unmount_fails=False,
                          user_mount=False, driver_uid=501):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            image = directory / 'image.ntfs'
            image.write_bytes(b'fixture')
            root = directory / 'mount'
            root.mkdir()
            log = directory / 'mount.log'
            state = {'mounted': False, 'unmounted': False, 'driverExited': False, 'unmountAttempted': False}

            class Driver:
                pid = 12345
                def poll(self):
                    return 0 if state['driverExited'] else None
                def wait(self, timeout=None):
                    if not state['unmounted'] and not (unmount_fails and state['unmountAttempted']):
                        raise AssertionError('driver lost before standard unmount')
                    state['driverExited'] = True
                    return 0
                def terminate(self):
                    raise AssertionError('must not terminate mounted driver')

            driver = Driver()

            class Unmount:
                def wait(self, timeout=None):
                    if state['driverExited']:
                        raise AssertionError('unmount needs the live driver')
                    state['unmountAttempted'] = True
                    if unmount_fails:
                        return 1
                    state['mounted'] = False
                    state['unmounted'] = True
                    return 0

            def popen(args, **kwargs):
                if args[0] == '/sbin/umount':
                    self.assertEqual(args, ['/sbin/umount', str(root)])
                    return Unmount()
                state['mounted'] = True
                if interrupt:
                    signal.raise_signal(signal.SIGINT)
                return driver

            def run(args, **kwargs):
                if args == ['/sbin/mount']:
                    flags = ', read-only' if read_only else ''
                    data = (f'/dev/disk99 on {root} (macfuse, local, fskit{flags})\n'
                            if state['mounted'] else '').encode()
                elif args[0] == '/usr/sbin/diskutil':
                    data = plistlib.dumps({'DeviceNode': '/dev/disk99', 'WholeDisk': True,
                                           'VirtualOrPhysical': 'Virtual', 'BusProtocol': 'Disk Image',
                                           'TotalSize': 4096})
                elif args[0] == '/usr/sbin/lsof':
                    data = f'p{driver.pid}\nn{image}\n'.encode()
                elif args[0] == '/bin/ps':
                    data = f'{driver_uid} {driver_uid} 20 20\n'.encode()
                else:
                    raise AssertionError(args)
                return subprocess.CompletedProcess(args, 0, data, b'')

            original_stat = os.stat
            def stat_call(path, *args, **kwargs):
                info = original_stat(path, *args, **kwargs)
                if Path(path) == root:
                    fields = list(info)
                    fields[2] += 100
                    return os.stat_result(fields)
                return info

            error = result = None
            with (patch('subprocess.Popen', side_effect=popen), patch('subprocess.run', side_effect=run),
                  patch('os.stat', side_effect=stat_call)):
                try:
                    result = probe_mount(image, root, log, user_mount=user_mount)
                except (TargetError, InterruptedError) as caught:
                    error = caught
            return state, error, result

    def test_rejected_writable_check_unmounts_with_driver_alive_before_exit(self):
        state, error, _ = self.run_mount_fixture()
        self.assertEqual(str(error), 'mountNotWritable')
        self.assertTrue(state['unmounted'])
        self.assertTrue(state['driverExited'])

    def test_success_requires_standard_unmount_and_driver_exit(self):
        state, error, result = self.run_mount_fixture(read_only=False)
        self.assertIsNone(error)
        self.assertIn('(macfuse, local, fskit)', result)
        self.assertTrue(state['unmounted'])
        self.assertTrue(state['driverExited'])

    def test_candidate_still_running_as_root_is_rejected_and_normally_unmounted(self):
        state, error, result = self.run_mount_fixture(read_only=False, user_mount=True, driver_uid=0)
        self.assertEqual(str(error), 'driverIdentityNotDropped')
        self.assertIsNone(result)
        self.assertTrue(state['unmounted'])
        self.assertTrue(state['driverExited'])

    def test_candidate_user_identity_can_finish_and_normally_unmount(self):
        state, error, result = self.run_mount_fixture(read_only=False, user_mount=True)
        self.assertIsNone(error)
        self.assertIsNotNone(result)
        self.assertTrue(state['unmounted'])
        self.assertTrue(state['driverExited'])

    def test_interrupt_during_process_start_still_unmounts_before_driver_exit(self):
        state, error, _ = self.run_mount_fixture(interrupt=True)
        self.assertIsInstance(error, InterruptedError)
        self.assertTrue(state['unmounted'])
        self.assertTrue(state['driverExited'])

    def test_unmount_failure_waits_for_live_driver_without_terminating_or_claiming_success(self):
        state, error, result = self.run_mount_fixture(unmount_fails=True)
        self.assertEqual(str(error), 'probeUnmountFailed')
        self.assertIsNone(result)
        self.assertTrue(state['mounted'])
        self.assertFalse(state['unmounted'])
        self.assertTrue(state['driverExited'])

    def test_failed_driver_with_no_mount_never_invokes_unmount(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory).resolve()
            image = directory / 'image.ntfs'
            image.write_bytes(b'fixture')
            class Driver:
                def poll(self): return 3
                def wait(self, timeout=None): return 3
            with (patch('subprocess.Popen', return_value=Driver()) as start,
                  patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0, b'', b''))):
                with self.assertRaisesRegex(TargetError, 'mountProcessExited'):
                    probe_mount(image, directory / 'mount', directory / 'mount.log')
            self.assertEqual(len(start.call_args_list), 1)


if __name__ == '__main__':
    unittest.main()
