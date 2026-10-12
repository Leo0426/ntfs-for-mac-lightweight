"""Safe process/file fixtures: no disk utilities or prepare entry point."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import prepare_usb_target as prep
from usb_target import TargetError


class PreparationOwnershipChecks(unittest.TestCase):
    def fixture(self, root, delay=0.15):
        output = root / 'finished'
        return [sys.executable, '-c',
                'import pathlib,time; time.sleep(float(__import__("sys").argv[1])); '
                'pathlib.Path(__import__("sys").argv[2]).write_text("finished")', str(delay), str(output)], output

    def owner(self, root, events):
        self.assertTrue(hasattr(prep, 'PreparationOwner'), 'prepare must retain a shared mutation owner')
        return prep.PreparationOwner(root / 'lease', owner_uid=os.getuid(),
                                     report=lambda stage, **values: events.append(stage), retry_interval=0.01)

    def competitor(self, path):
        child = subprocess.run([sys.executable, '-c',
            'import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDWR); '
            'fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)', str(path)], capture_output=True)
        return child.returncode

    def test_timeout_retains_lease_until_real_exit_and_fresh_postcondition(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); events = []
            args, output = self.fixture(root)
            owner = self.owner(root, events)
            checks = []
            def after():
                self.assertTrue(output.exists(), 'fresh evidence only after real child exit')
                self.assertNotEqual(self.competitor(root / 'lease'), 0)
                checks.append(True)
            with owner, self.assertRaisesRegex(TargetError, 'mutationDeadlineExceeded'):
                owner.mutate(args, before=lambda: None, after=after, timeout=0.01)
            self.assertTrue(checks)
            self.assertIn('quiescencePending', events)
            self.assertEqual(self.competitor(root / 'lease'), 0)

    def test_interrupt_does_not_kill_child_or_release_competing_lease(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); events = []
            args, output = self.fixture(root)
            owner = self.owner(root, events)
            timer = threading.Timer(0.04, lambda: os.kill(os.getpid(), signal.SIGINT))
            with owner:
                timer.start()
                try:
                    with self.assertRaisesRegex(TargetError, 'mutationInterrupted'):
                        owner.mutate(args, before=lambda: None,
                                     after=lambda: self.assertTrue(output.exists()), timeout=2)
                finally:
                    timer.join()
            self.assertTrue(output.exists())
            self.assertIn('quiescencePending', events)

    def test_command_exit_does_not_release_owner_while_facts_unknown(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); events = []
            args, output = self.fixture(root, 0.01)
            attempts = []
            owner = self.owner(root, events)
            def after():
                self.assertTrue(output.exists())
                self.assertNotEqual(self.competitor(root / 'lease'), 0)
                attempts.append(True)
                if len(attempts) < 3:
                    raise TargetError('externalSystemStillPending')
            with owner:
                owner.mutate(args, before=lambda: None, after=after, timeout=1)
            self.assertEqual(len(attempts), 3)
            self.assertIn('systemFactsPending', events)

    def test_precondition_failure_never_starts_child(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); events = []
            args, output = self.fixture(root, 0)
            owner = self.owner(root, events)
            def before(): raise TargetError('targetChanged')
            with owner, self.assertRaisesRegex(TargetError, 'targetChanged'):
                owner.mutate(args, before=before, after=lambda: None)
            self.assertFalse(output.exists())

    def test_duplicate_owner_refused_and_shared_usb_lab_lease(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); events = []
            with self.owner(root, events):
                with self.assertRaises((TargetError, BlockingIOError)):
                    with self.owner(root, events): pass
            import isolation_resources as resources
            import usb_lab
            self.assertEqual(prep.LEASE_PATH, resources.LEASE_PATH)
            self.assertEqual(usb_lab.LEASE_PATH, resources.LEASE_PATH)

    def test_closed_terminal_does_not_unwind_pending_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args, output = self.fixture(root, 0.06)
            self.assertTrue(hasattr(prep, 'PreparationOwner'))
            def closed(*_args, **_kwargs): raise BrokenPipeError('closed terminal')
            with prep.PreparationOwner(root / 'lease', owner_uid=os.getuid(), report=closed) as owner:
                with self.assertRaisesRegex(TargetError, 'mutationDeadlineExceeded'):
                    owner.mutate(args, before=lambda: None, after=lambda: self.assertTrue(output.exists()), timeout=0.01)
            self.assertTrue(output.exists())

    def test_shared_lease_rejects_links_and_writable_metadata(self):
        import isolation_resources as resources
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = root / 'target'; target.write_text(''); target.chmod(0o600)
            link = root / 'link'; link.symlink_to(target)
            with self.assertRaises(OSError):
                with resources.IsolationLease(link, owner_uid=os.getuid()): pass
            hardlink = root / 'hardlink'; os.link(target, hardlink)
            with self.assertRaisesRegex(TargetError, 'unsafeLeaseFile'):
                with resources.IsolationLease(target, owner_uid=os.getuid()): pass
            hardlink.unlink(); target.chmod(0o666)
            with self.assertRaisesRegex(TargetError, 'unsafeLeaseFile'):
                with resources.IsolationLease(target, owner_uid=os.getuid()): pass

    def test_shared_wait_reaps_then_propagates_interrupt_to_stop_lab_sequence(self):
        from isolation_resources import wait_for_mutation
        with tempfile.TemporaryDirectory() as folder:
            args, output = self.fixture(Path(folder), 0.12)
            child = subprocess.Popen(args, start_new_session=True)
            timer = threading.Timer(0.03, lambda: os.kill(os.getpid(), signal.SIGINT))
            timer.start()
            try:
                with self.assertRaises(InterruptedError):
                    wait_for_mutation(child, timeout=1)
                self.assertIsNotNone(child.poll())
                self.assertTrue(output.exists())
            finally:
                timer.join()
                child.wait()

    def test_lab_mutation_is_detached_from_terminal_signal_group(self):
        from usb_lab import USBLab
        import json
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); output = root / 'session'
            lab = USBLab.__new__(USBLab)
            lab.folder, lab.counter, lab.owner, lab.pending_mutation = root, 0, os.getuid(), None
            lab.mutation([sys.executable, '-c',
                          'import os,json,pathlib,sys; pathlib.Path(sys.argv[1]).write_text('
                          'json.dumps([os.getpid(),os.getsid(0)]))', str(output)])
            pid, sid = json.loads(output.read_text())
            self.assertEqual(pid, sid, 'terminal Ctrl-C must not kill a lab mutation child')
