from contextlib import nullcontext
import errno
import io
import json
from pathlib import Path
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import usb_lab
from usb_lab import failure_details, main
from usb_target import TargetError


class USBDiagnosticChecks(unittest.TestCase):
    def setUp(self):
        expected = {'mediaName': 'U310', 'physicalBytes': 32212254720, 'partitionBytes': 32000442368}
        self.facts = {'node': '/dev/disk6s2', 'disk': 'disk6', 'writable': False}
        self.enterContext(patch('usb_lab.private_target', return_value=expected))
        self.enterContext(patch('usb_lab.stable_snapshot', return_value=self.facts))
        self.enterContext(patch('usb_lab.block_device_info', return_value=SimpleNamespace(st_rdev=16777242)))
        self.enterContext(patch('usb_lab.dependencies'))
        self.candidate = self.enterContext(patch('usb_lab.candidate', return_value=Path('/fixture/ntfs-3g')))
        self.identity = self.enterContext(patch('usb_lab.filesystem_identity', side_effect=nullcontext))
        self.enterContext(patch('usb_lab.os.geteuid', return_value=0))
        self.open = self.enterContext(patch('usb_lab.os.open', return_value=42))
        self.enterContext(patch('usb_lab.os.fstat', return_value=SimpleNamespace(
            st_mode=stat.S_IFREG | 0o600, st_uid=0, st_nlink=1)))
        self.enterContext(patch('usb_lab.fcntl.flock'))
        self.enterContext(patch('usb_lab.os.close'))
        self.enterContext(patch('usb_lab.signal.signal'))
        self.cycle = self.enterContext(patch('usb_lab.complete_cycle'))

    def invoke_lines(self, mode):
        output = io.StringIO()
        with patch('usb_lab.sys.argv', ['usb_lab.py', mode]), patch('usb_lab.sys.stdout', output):
            code = main()
        return code, [json.loads(line) for line in output.getvalue().splitlines()]

    def invoke(self, mode):
        code, reports = self.invoke_lines(mode)
        self.assertEqual(len(reports), 1)
        return code, reports[0]

    def test_inspect_rejects_changed_mount_candidate_without_reporting_match(self):
        self.candidate.side_effect = TargetError('mountCandidateDigestChanged')
        code, report = self.invoke('--inspect')
        self.assertEqual(code, 1)
        self.assertEqual(report['stage'], 'blocked')
        self.assertEqual(report['operation'], 'candidateCheck')
        self.assertEqual(report['reason'], 'mountCandidateDigestChanged')
        self.assertFalse(report['diskMutationsPerformed'])

    def test_inspect_rejects_unusable_file_check_identity(self):
        self.identity.side_effect = TargetError('unexpectedSupervisorIdentity')
        code, report = self.invoke('--inspect')
        self.assertEqual(code, 1)
        self.assertEqual(report['operation'], 'candidateCheck')
        self.assertEqual(report['reason'], 'unexpectedSupervisorIdentity')

    def test_inspect_match_reports_verified_run_candidate(self):
        code, report = self.invoke('--inspect')
        self.assertEqual(code, 0)
        self.assertEqual(report['stage'], 'targetMatched')
        self.assertTrue(report['mountCandidateVerified'])
        self.candidate.assert_called_once()
        self.identity.assert_called_once()
        self.open.assert_not_called()

    def test_run_candidate_failure_stops_before_lease_or_experiment(self):
        self.candidate.side_effect = TargetError('mountCandidateDigestChanged')
        with patch('usb_lab.USBLab') as lab:
            code, report = self.invoke('--run')
        self.assertEqual(code, 1)
        self.assertEqual(report['operation'], 'candidateCheck')
        self.assertFalse(report['diskMutationsPerformed'])
        lab.assert_not_called()
        self.open.assert_not_called()

    def test_run_failure_is_recorded_before_waiting_for_driver(self):
        order = []
        lab = MagicMock()
        lab.journal.side_effect = lambda stage, **values: order.append(('journal', stage, values))
        lab.stop_after_failure.side_effect = lambda: order.append(('stop',))
        self.cycle.side_effect = TargetError('mountProcessExited')
        with patch('usb_lab.USBLab', return_value=lab):
            code, _ = self.invoke_lines('--run')
        self.assertEqual(code, 1)
        self.assertEqual([item[:2] for item in order],
                         [('journal', 'failed'), ('stop',), ('journal', 'failureHandlingFinished')])
        self.assertEqual(order[0][2]['reason'], 'mountProcessExited')
        self.assertEqual(order[0][2]['operation'], 'fileCycle')

    def test_run_failure_still_stops_and_reports_when_journal_is_unwritable(self):
        lab = MagicMock()
        lab.journal.side_effect = OSError(errno.ENOSPC, 'private text')
        lab.folder = Path('/fixture/usb-run-x')
        self.cycle.side_effect = TargetError('mountProcessExited')
        with patch('usb_lab.USBLab', return_value=lab):
            code, reports = self.invoke_lines('--run')
        self.assertEqual(code, 1)
        lab.stop_after_failure.assert_called_once()
        failed = [report for report in reports if report['stage'] == 'failed']
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0]['reason'], 'mountProcessExited')
        self.assertFalse(failed[0]['journalRecorded'])
        self.assertNotIn('private', json.dumps(reports))

    def test_failure_reports_innermost_call_site_without_directory_path(self):
        def fsync_step():
            raise OSError(errno.EOPNOTSUPP, 'private text', '/private/secret/file')
        try:
            fsync_step()
        except OSError as error:
            details = failure_details(error, 'fileCycle')
        self.assertRegex(details['failedAt'], r'^test_usb_diagnostics\.py:fsync_step:[0-9]+$')
        self.assertEqual(details['errnoName'], 'EOPNOTSUPP')
        self.assertNotIn('private', json.dumps(details))

    def test_root_started_driver_keeps_upstream_silent_after_disabling_default_options(self):
        # no_def_opts cancels NTFS-3G's default `silent`; without it, chown of a new entry to
        # the file-operation user (uid 501) differs from the root context uid and fails.
        options = usb_lab.OPTIONS.split(',')
        self.assertIn('silent', options)
        self.assertGreater(options.index('silent'), options.index('no_def_opts'))
        self.assertFalse({'allow_other', 'nonempty', 'permissions'} & set(options))

    def test_usb_driver_logs_its_own_errors(self):
        self.assertNotIn('quiet', usb_lab.OPTIONS.split(','))

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
