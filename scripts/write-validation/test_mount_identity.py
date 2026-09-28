import os
import unittest
import subprocess
from types import SimpleNamespace
from unittest.mock import patch

from user_mount_candidate import filesystem_identity
from usb_lab import query


class MountIdentityChecks(unittest.TestCase):
    def test_independent_readback_child_gets_permanent_user_credentials(self):
        def run(args, **options):
            self.assertEqual(options['user'], 501)
            self.assertEqual(options['group'], 20)
            self.assertEqual(options['extra_groups'], [20])
            return subprocess.CompletedProcess(args, 0, b'fixture', b'')
        with patch('os.geteuid', return_value=0), patch('subprocess.run', side_effect=run):
            self.assertEqual(query(['/fixture/verify-files'], as_mount_user=True), b'fixture')

    def test_filesystem_exception_restores_supervisor_identity(self):
        state = {'uid': 0, 'gid': 0, 'groups': [0, 12]}
        def group_query(count, values):
            if count:
                for index, group in enumerate(state['groups']):
                    values[index] = group
            return len(state['groups'])
        with (patch('os.getuid', return_value=0), patch('os.getgid', return_value=0),
              patch('os.geteuid', side_effect=lambda: state['uid']),
              patch('os.getegid', side_effect=lambda: state['gid']),
              patch('os.getgroups', return_value=[20, 99]),
              patch('ctypes.CDLL', return_value=SimpleNamespace(getgroups=group_query)),
              patch('os.seteuid', side_effect=lambda value: state.update(uid=value)),
              patch('os.setegid', side_effect=lambda value: state.update(gid=value)),
              patch('os.setgroups', side_effect=lambda value: state.update(groups=value))):
            with self.assertRaisesRegex(ValueError, 'file check failed'):
                with filesystem_identity():
                    self.assertEqual(state, {'uid': 501, 'gid': 20, 'groups': [20]})
                    raise ValueError('file check failed')
            self.assertEqual(state, {'uid': 0, 'gid': 0, 'groups': [0, 12]})


if __name__ == '__main__':
    unittest.main()
