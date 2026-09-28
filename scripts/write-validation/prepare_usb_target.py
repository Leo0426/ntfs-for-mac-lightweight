"""One-time preparation of the user-designated sacrificial USB disk; run manually through sudo.

Authorized by the user on 2026-09-28 for the XMUP22YM disk that then held only a macOS
installer. Pinned identity only: no device argument, no other disk, no recovery options.
Erases the whole disk into GPT (EFI + Microsoft Basic Data), formats NTFS with the pinned
mkntfs, lets macOS mount it natively read-only, and writes the private target receipt
whose digest must then be reviewed and pinned into usb_lab.py.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from usb_target import TargetError, require

BASE = Path(__file__).resolve().parents[2]
MEDIA_NAME = 'XMUP22YM'
PHYSICAL_BYTES = 124623257600
ORIGINAL_VOLUME = 'Install macOS 27 Golden Gate'
LABEL = 'NTFSLAB'
EFI_BYTES = 209715200
MKNTFS = BASE / '.build/dependency-candidates/ntfs-3g-build/ntfsprogs/mkntfs'
MKNTFS_SHA256 = '7790efde233476963eae4509581be220cbb1de991eb6bec3a1a2ab4824aec929'
RECEIPT = BASE / '.build/write-validation/approved-usb-target.json'
OWNER_UID, OWNER_GID = 501, 20


def emit(stage, **values):
    print(json.dumps({'stage': stage, **values}, sort_keys=True), flush=True)


def run(args, timeout=120):
    result = subprocess.run(args, capture_output=True, timeout=timeout)
    require(result.returncode == 0 and len(result.stdout) <= 4 * 1024**2, 'systemCommandFailed')
    return result.stdout


def plist(args):
    value = plistlib.loads(run(['/usr/sbin/diskutil', *args]))
    require(isinstance(value, dict), 'invalidSystemFacts')
    return value


def select_target(listing, info):
    """Return the one whole disk matching the pinned physical identity."""
    matches = []
    for disk in listing.get('AllDisksAndPartitions', []):
        whole = info(disk.get('DeviceIdentifier', ''))
        if (whole.get('MediaName') == MEDIA_NAME and whole.get('Size') == PHYSICAL_BYTES):
            matches.append((disk, whole))
    require(len(matches) == 1, 'targetAbsentOrAmbiguous')
    disk, whole = matches[0]
    require(re.fullmatch(r'disk[0-9]+', whole.get('DeviceIdentifier', '')) is not None
            and whole.get('WholeDisk') is True and whole.get('Internal') is False
            and whole.get('Removable') is True and whole.get('Ejectable') is True
            and whole.get('WritableMedia') is True and whole.get('BusProtocol') == 'USB'
            and whole.get('VirtualOrPhysical') == 'Physical', 'physicalTargetMismatch')
    return disk, whole


def check_original(disk):
    parts = disk.get('Partitions', [])
    require(len(parts) == 2 and parts[0].get('Content') == 'EFI'
            and parts[1].get('VolumeName') == ORIGINAL_VOLUME, 'unexpectedOriginalContents')
    require(not disk.get('APFSVolumes') and not any(p.get('APFSVolumes') for p in parts),
            'unexpectedOriginalContents')


def check_erased(disk):
    parts = disk.get('Partitions', [])
    require(len(parts) == 2, 'erasedLayoutMismatch')
    efi, data = parts
    require(efi.get('Content') == 'EFI' and efi.get('Size') == EFI_BYTES
            and efi.get('MountPoint', '') == '', 'erasedLayoutMismatch')
    require(data.get('Content') == 'Microsoft Basic Data'
            and re.fullmatch(re.escape(disk['DeviceIdentifier']) + r's[0-9]+',
                             data.get('DeviceIdentifier', '')) is not None, 'erasedLayoutMismatch')
    return efi, data


def receipt_bytes(efi, data):
    value = {'efiUUID': efi['DiskUUID'], 'mediaName': MEDIA_NAME,
             'partitionBytes': data['Size'], 'partitionUUID': data['DiskUUID'],
             'physicalBytes': PHYSICAL_BYTES}
    require(all(isinstance(value[k], str) and value[k] for k in ['efiUUID', 'partitionUUID'])
            and type(value['partitionBytes']) is int, 'invalidReceiptFacts')
    return (json.dumps(value, sort_keys=True) + '\n').encode()


def fresh_target():
    listing = plist(['list', '-plist', 'external', 'physical'])
    return select_target(listing, lambda identifier: plist(['info', '-plist', identifier]))


def main():
    try:
        require(os.geteuid() == 0, 'administratorAuthenticationRequired')
        require(hashlib.sha256(MKNTFS.read_bytes()).hexdigest() == MKNTFS_SHA256,
                'mkntfsDigestChanged')
        disk, whole = fresh_target()
        check_original(disk)
        identifier = whole['DeviceIdentifier']
        emit('targetConfirmed', disk=identifier, media=MEDIA_NAME, physicalBytes=PHYSICAL_BYTES)

        run(['/usr/sbin/diskutil', 'eraseDisk', 'ExFAT', LABEL, 'GPT', identifier], timeout=600)
        disk, whole = fresh_target()
        require(whole['DeviceIdentifier'] == identifier, 'deviceRenumbered')
        efi, data = check_erased(disk)
        node = '/dev/' + data['DeviceIdentifier']
        emit('diskErased', partition=data['DeviceIdentifier'], partitionBytes=data['Size'])

        if data.get('MountPoint'):
            run(['/usr/sbin/diskutil', 'unmount', node])
        volume = plist(['info', '-plist', node])
        require(volume.get('MountPoint', '') == '' and volume.get('DiskUUID') == data['DiskUUID'],
                'partitionStillMountedOrChanged')
        offset = volume.get('PartitionMapPartitionOffset')
        require(type(offset) is int and offset > 0 and offset % 512 == 0, 'invalidPartitionOffset')
        run([str(MKNTFS), '--quick', '--label', LABEL, '--sector-size', '512',
             '--partition-start', str(offset // 512), '--heads', '255',
             '--sectors-per-track', '63', node], timeout=600)
        emit('ntfsFormatted', partition=data['DeviceIdentifier'])

        run(['/usr/sbin/diskutil', 'mount', node])
        deadline = time.monotonic() + 20
        while True:
            volume = plist(['info', '-plist', node])
            if volume.get('MountPoint'):
                break
            require(time.monotonic() < deadline, 'nativeMountNotObserved')
            time.sleep(0.5)
        require(volume.get('FilesystemType') == 'ntfs' and volume.get('WritableVolume') is False,
                'nativeReadOnlyNTFSMountRequired')
        disk, _ = fresh_target()
        efi, data = check_erased(disk)
        data_bytes = receipt_bytes(efi, data)

        if RECEIPT.exists():
            previous = RECEIPT.with_name('approved-usb-target-previous.json')
            require(not os.path.lexists(previous), 'previousReceiptBackupExists')
            os.rename(RECEIPT, previous)
        descriptor = os.open(RECEIPT, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'wb') as handle:
            handle.write(data_bytes)
            handle.flush()
            os.fsync(handle.fileno())
            os.fchown(handle.fileno(), OWNER_UID, OWNER_GID)
        emit('targetPrepared', mountpoint=volume['MountPoint'], nativeReadOnly=True,
             receiptSHA256=hashlib.sha256(data_bytes).hexdigest(),
             next='把 receiptSHA256 发回，由代码审查后固定到 usb_lab.py')
        return 0
    except BaseException as error:
        emit('failed', reason=str(error) if isinstance(error, TargetError) else type(error).__name__)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
