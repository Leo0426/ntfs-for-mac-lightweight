import copy
import unittest

from usb_target import TargetError, check_target, check_writable_mount


class USBTargetChecks(unittest.TestCase):
    def setUp(self):
        self.expected = {'physicalBytes': 32212254720, 'partitionBytes': 32000442368,
                         'partitionUUID': 'data-id', 'efiUUID': 'efi-id', 'mediaName': 'U310'}
        self.whole = {'DeviceIdentifier': 'disk6', 'WholeDisk': True, 'Internal': False,
                      'BusProtocol': 'USB', 'Removable': True, 'Ejectable': True,
                      'WritableMedia': True, 'Size': 32212254720, 'MediaName': 'U310'}
        self.volume = {'DeviceIdentifier': 'disk6s2', 'DeviceNode': '/dev/disk6s2',
                       'ParentWholeDisk': 'disk6', 'DiskUUID': 'data-id', 'WholeDisk': False,
                       'Internal': False, 'WritableMedia': True, 'Size': 32000442368,
                       'MountPoint': '/Volumes/Test', 'FilesystemType': 'ntfs', 'WritableVolume': False}
        self.parts = [{'DeviceIdentifier': 'disk6s1', 'DiskUUID': 'efi-id', 'Content': 'EFI',
                       'Size': 209715200},
                      {'DeviceIdentifier': 'disk6s2', 'DiskUUID': 'data-id',
                       'Content': 'Microsoft Basic Data', 'Size': 32000442368,
                       'MountPoint': '/Volumes/Test'}]

    def check(self):
        return check_target(self.expected, self.whole, self.volume, self.parts)

    def test_bsd_renumbering_requires_same_complete_partition_identity(self):
        self.assertEqual(self.check(), ('disk6', '/dev/disk6s2'))
        self.whole['DeviceIdentifier'] = 'disk9'
        self.volume.update(DeviceIdentifier='disk9s2', DeviceNode='/dev/disk9s2', ParentWholeDisk='disk9')
        for i, part in enumerate(self.parts, 1):
            part['DeviceIdentifier'] = f'disk9s{i}'
        self.assertEqual(self.check(), ('disk9', '/dev/disk9s2'))
        self.volume['DiskUUID'] = 'replacement'
        with self.assertRaises(TargetError):
            self.check()

    def test_unknown_internal_and_non_usb_media_fail_closed(self):
        for key, values in {'Internal': [True, None, 0], 'Removable': [False, None, 1],
                            'Ejectable': [False, None, 1], 'BusProtocol': ['PCI-Express', None],
                            'WholeDisk': [False, None], 'Size': [32000000000, None],
                            'WritableMedia': [False, None]}.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    original = self.whole[key]
                    self.whole[key] = value
                    with self.assertRaises(TargetError):
                        self.check()
                    self.whole[key] = original

    def test_extra_missing_replaced_or_mounted_sibling_is_rejected(self):
        for kind in ['extra', 'missing', 'replacement', 'mounted']:
            with self.subTest(kind=kind):
                original = copy.deepcopy(self.parts)
                if kind == 'extra':
                    self.parts.append({'DeviceIdentifier': 'disk6s3'})
                elif kind == 'missing':
                    self.parts.pop(0)
                elif kind == 'replacement':
                    self.parts[0]['DiskUUID'] = 'different-efi'
                else:
                    self.parts[0]['MountPoint'] = '/Volumes/EFI'
                with self.assertRaises(TargetError):
                    self.check()
                self.parts = original

    def test_volume_and_topology_disagreement_or_device_injection_is_rejected(self):
        for key, value in [('ParentWholeDisk', 'disk0'), ('DeviceNode', '/dev/disk0s2'),
                           ('Size', 1), ('Internal', True), ('WholeDisk', True),
                           ('MountPoint', '/Volumes/Other'), ('DeviceIdentifier', 'disk6s2; command')]:
            with self.subTest(key=key):
                original = self.volume[key]
                self.volume[key] = value
                with self.assertRaises(TargetError):
                    self.check()
                self.volume[key] = original

    def test_only_exact_device_and_fskit_writable_mount_are_accepted(self):
        line = '/dev/disk6s2 on /Volumes/Lab (macfuse, local, nodev, nosuid, fskit)'
        self.assertEqual(check_writable_mount([line], '/dev/disk6s2', '/Volumes/Lab'), line)
        for lines in [[], [line, line], [line.replace('disk6s2', 'disk7s2')],
                      [line.replace('fskit', 'read-only, fskit')],
                      [line.replace(', fskit', '')], [line.replace('macfuse,', 'ntfs,')],
                      [line.replace('local, ', '')]]:
            with self.subTest(lines=lines), self.assertRaises(TargetError):
                check_writable_mount(lines, '/dev/disk6s2', '/Volumes/Lab')


if __name__ == '__main__':
    unittest.main()
