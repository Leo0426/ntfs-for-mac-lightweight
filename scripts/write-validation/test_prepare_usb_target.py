import unittest

import prepare_usb_target as prep
from usb_target import TargetError


def whole(identifier='disk8', **changes):
    value = {'DeviceIdentifier': identifier, 'MediaName': prep.MEDIA_NAME, 'Size': prep.PHYSICAL_BYTES,
             'WholeDisk': True, 'Internal': False, 'Removable': True, 'Ejectable': True,
             'WritableMedia': True, 'BusProtocol': 'USB', 'VirtualOrPhysical': 'Physical'}
    value.update(changes)
    return value


class PrepareTargetChecks(unittest.TestCase):
    def select(self, infos):
        listing = {'AllDisksAndPartitions': [{'DeviceIdentifier': i} for i in infos]}
        return prep.select_target(listing, infos.__getitem__)

    def test_selects_only_pinned_physical_usb_disk(self):
        _, info = self.select({'disk4': whole('disk4', MediaName='Other'), 'disk8': whole()})
        self.assertEqual(info['DeviceIdentifier'], 'disk8')

    def test_rejects_absent_duplicate_internal_or_virtual_target(self):
        for infos in [{'disk4': whole('disk4', Size=1)},
                      {'disk4': whole('disk4'), 'disk8': whole()},
                      {'disk8': whole(Internal=True)},
                      {'disk8': whole(VirtualOrPhysical='Virtual')},
                      {'disk8': whole(BusProtocol='SATA')}]:
            with self.subTest(infos=infos), self.assertRaises(TargetError):
                self.select(infos)

    def test_erase_requires_the_user_named_installer_volume(self):
        good = {'Partitions': [{'Content': 'EFI'}, {'VolumeName': prep.ORIGINAL_VOLUME}]}
        prep.check_original(good)
        for disk in [{'Partitions': [{'Content': 'EFI'}, {'VolumeName': 'Photos'}]},
                     {'Partitions': good['Partitions'] + [{'VolumeName': 'Extra'}]},
                     {**good, 'APFSVolumes': [{}]}]:
            with self.subTest(disk=disk), self.assertRaises(TargetError):
                prep.check_original(disk)

    def test_erased_layout_must_match_usb_lab_topology(self):
        efi = {'Content': 'EFI', 'Size': prep.EFI_BYTES, 'DiskUUID': 'E'}
        data = {'Content': 'Microsoft Basic Data', 'DeviceIdentifier': 'disk8s2', 'Size': 5, 'DiskUUID': 'D'}
        self.assertEqual(prep.check_erased({'DeviceIdentifier': 'disk8', 'Partitions': [efi, data]}), (efi, data))
        for parts in [[efi], [efi, {**data, 'Content': 'Apple_HFS'}], [{**efi, 'MountPoint': '/Volumes/EFI'}, data],
                      [efi, {**data, 'DeviceIdentifier': 'disk9s2'}]]:
            with self.subTest(parts=parts), self.assertRaises(TargetError):
                prep.check_erased({'DeviceIdentifier': 'disk8', 'Partitions': parts})


if __name__ == '__main__': unittest.main()
