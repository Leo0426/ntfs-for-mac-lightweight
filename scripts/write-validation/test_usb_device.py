"""Exercise the same device-reading path as the administrator USB run without disk I/O."""
import os
import errno
import io
import json
import stat
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from usb_lab import USBLab, main
from usb_target import TargetError


class USBDeviceChecks(unittest.TestCase):
    def setUp(self):
        self.lab = USBLab.__new__(USBLab)
        self.lab.node = '/dev/disk6s2'
        self.lab.device_rdev = 16777242
        self.block = self.info(stat.S_IFBLK)
        self.raw = self.info(stat.S_IFCHR, inode=125)
        self.nodes = {self.lab.node: self.block, '/dev/rdisk6s2': self.raw}
        boot = bytearray(512)
        boot[3:11] = b'NTFS    '
        boot[72:80] = b'12345678'
        boot[510:512] = b'\x55\xaa'
        self.boot = bytes(boot)
        self.named = self.enterContext(patch('usb_lab.os.lstat', side_effect=self.nodes.__getitem__))
        self.opened = self.enterContext(patch('usb_lab.os.open', return_value=42))
        self.descriptor = self.enterContext(patch('usb_lab.os.fstat', return_value=self.raw))
        self.read = self.enterContext(patch('usb_lab.os.read', return_value=self.boot))
        self.close = self.enterContext(patch('usb_lab.os.close'))

    def info(self, kind, rdev=16777242, inode=123):
        return SimpleNamespace(st_mode=kind | 0o640, st_rdev=rdev, st_dev=1234, st_ino=inode)

    def test_paired_raw_node_reads_exact_boot_sector_read_only(self):
        self.assertEqual(self.lab.read_boot(), self.boot)
        self.opened.assert_called_once_with('/dev/rdisk6s2', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        self.read.assert_called_once_with(42, 512)
        self.close.assert_called_once_with(42)

    def test_mounted_block_device_uses_matching_raw_node_for_read_only_boot_read(self):
        raw = self.info(stat.S_IFCHR, inode=125)
        nodes = {self.lab.node: self.block, '/dev/rdisk6s2': raw}
        self.named.side_effect = nodes.__getitem__
        self.descriptor.return_value = raw
        def open_device(node, flags):
            if node == self.lab.node:
                raise OSError(errno.EBUSY, 'mounted block device')
            self.assertEqual(node, '/dev/rdisk6s2')
            self.assertEqual(flags, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            return 42
        self.opened.side_effect = open_device
        self.assertEqual(self.lab.read_boot(), self.boot)
        self.read.assert_called_once_with(42, 512)
        self.close.assert_called_once_with(42)

    def test_inspect_checks_node_type_without_opening_the_device(self):
        expected = {'mediaName': 'U310', 'physicalBytes': 32212254720, 'partitionBytes': 32000442368}
        for kind, code in [(stat.S_IFBLK, 0), (stat.S_IFCHR, 1)]:
            with self.subTest(kind=kind):
                self.nodes[self.lab.node] = self.info(kind)
                output = io.StringIO()
                with patch('usb_lab.sys.argv', ['usb_lab.py', '--inspect']), \
                     patch('usb_lab.private_target', return_value=expected), \
                     patch('usb_lab.stable_snapshot', return_value={'node': self.lab.node, 'writable': False}), \
                     patch('usb_lab.dependencies'), patch('usb_lab.run_preflight'), \
                     patch('usb_lab.sys.stdout', output):
                    self.assertEqual(main(), code)
                report = json.loads(output.getvalue())
                self.assertFalse(report['diskMutationsPerformed'])
                if code == 0:
                    self.assertEqual(report['deviceNodeType'], 'block')
                else:
                    self.assertEqual(report['reason'], 'notBlockDevice')
                self.opened.assert_not_called()
                self.read.assert_not_called()

    def test_character_symlink_regular_and_fifo_nodes_are_rejected_before_open(self):
        for kind in [stat.S_IFCHR, stat.S_IFLNK, stat.S_IFREG, stat.S_IFIFO, stat.S_IFDIR]:
            with self.subTest(kind=kind):
                self.nodes[self.lab.node] = self.info(kind)
                with self.assertRaisesRegex(TargetError, 'notBlockDevice'):
                    self.lab.read_boot()
                self.opened.assert_not_called()
                self.read.assert_not_called()

    def test_changed_device_number_is_rejected_before_open(self):
        self.nodes[self.lab.node] = self.info(stat.S_IFBLK, rdev=999)
        with self.assertRaisesRegex(TargetError, 'deviceChanged'):
            self.lab.read_boot()
        self.opened.assert_not_called()

    def test_opened_node_type_number_or_identity_change_prevents_read(self):
        for replacement in [self.info(stat.S_IFBLK), self.info(stat.S_IFCHR, rdev=999),
                            self.info(stat.S_IFCHR, inode=999)]:
            with self.subTest(replacement=replacement):
                self.descriptor.return_value = replacement
                with self.assertRaises(TargetError):
                    self.lab.read_boot()
                self.read.assert_not_called()
        self.assertEqual(self.close.call_count, 3)

    def test_named_node_replacement_during_read_discards_boot_result(self):
        for node, kind in [(self.lab.node, stat.S_IFBLK), ('/dev/rdisk6s2', stat.S_IFCHR)]:
            for replacement in [self.info(stat.S_IFREG), self.info(kind, rdev=999),
                                self.info(kind, inode=999)]:
                with self.subTest(node=node, replacement=replacement):
                    self.nodes.update({self.lab.node: self.block, '/dev/rdisk6s2': self.raw})
                    def replaced_read(_fd, _size):
                        self.nodes[node] = replacement
                        return self.boot
                    self.read.side_effect = replaced_read
                    with self.assertRaises(TargetError):
                        self.lab.read_boot()
        self.assertEqual(self.close.call_count, 6)

    def test_invalid_or_mismatched_raw_node_is_rejected_before_open(self):
        replacements = [self.info(kind) for kind in
                        [stat.S_IFBLK, stat.S_IFLNK, stat.S_IFREG, stat.S_IFIFO, stat.S_IFDIR]]
        replacements.append(self.info(stat.S_IFCHR, rdev=999))
        other_filesystem = self.info(stat.S_IFCHR)
        other_filesystem.st_dev = 999
        replacements.append(other_filesystem)
        for replacement in replacements:
            with self.subTest(replacement=replacement):
                self.nodes['/dev/rdisk6s2'] = replacement
                with self.assertRaises(TargetError):
                    self.lab.read_boot()
                self.opened.assert_not_called()
                self.read.assert_not_called()

    def test_raw_path_can_only_be_derived_from_an_exact_disk_partition_node(self):
        for node in ['/dev/disk6', '/dev/rdisk6s2', '/tmp/disk6s2', '/dev/disk6s2/../disk0s1']:
            with self.subTest(node=node):
                self.lab.node = node
                with self.assertRaisesRegex(TargetError, 'invalidBlockDevicePath'):
                    self.lab.read_boot()
                self.named.assert_not_called()
                self.opened.assert_not_called()

    def test_truncated_or_invalid_ntfs_boot_sector_is_rejected(self):
        for contents in [b'', self.boot[:511], b'\0' * 512, self.boot[:72] + b'\0' * 8 + self.boot[80:]]:
            with self.subTest(length=len(contents)):
                self.read.return_value = contents
                with self.assertRaisesRegex(TargetError, 'invalidNTFSBootSector'):
                    self.lab.read_boot()
        self.assertEqual(self.close.call_count, 4)

    def test_open_failure_preserves_operation_and_errno_without_reading(self):
        self.opened.side_effect = OSError(errno.EBUSY, 'private path')
        with self.assertRaises(TargetError) as raised:
            self.lab.read_boot()
        self.assertEqual(raised.exception.operation, 'bootDeviceOpen')
        self.assertEqual(raised.exception.errno, errno.EBUSY)
        self.read.assert_not_called()
        self.close.assert_not_called()

    def test_read_failure_preserves_operation_and_errno_and_closes_descriptor(self):
        self.read.side_effect = OSError(errno.EINVAL, 'private path')
        with self.assertRaises(TargetError) as raised:
            self.lab.read_boot()
        self.assertEqual(raised.exception.operation, 'bootSectorRead')
        self.assertEqual(raised.exception.errno, errno.EINVAL)
        self.close.assert_called_once_with(42)


if __name__ == '__main__':
    unittest.main()
