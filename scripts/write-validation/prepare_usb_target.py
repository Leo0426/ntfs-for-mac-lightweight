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
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from usb_target import TargetError, require
from isolation_resources import IsolationLease, LEASE_PATH, retain_interrupts, wait_for_mutation

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



class PreparationOwner(IsolationLease):
    """Hold the shared lease until child reaping AND fresh system postconditions."""
    def __init__(self, path=LEASE_PATH, owner_uid=0, report=emit, retry_interval=1):
        super().__init__(path, owner_uid)
        def safe_report(*args, **values):
            try:
                report(*args, **values)
            except Exception:
                # A closed terminal or broken journal cannot release a live mutation.
                pass
        self.report, self.retry_interval = safe_report, retry_interval
        self.child = None
        self._after = None

    def __exit__(self, *error):
        if self.child is not None:
            with retain_interrupts(self.report):
                while self.child is not None:
                    try:
                        wait_for_mutation(self.child, pending=lambda: self.report('quiescencePending'))
                        self.complete(self._after)
                        self.child = None
                    except BaseException as failure:
                        self.report('systemFactsPending', lease=str(self.path), reason=type(failure).__name__)
                        time.sleep(self.retry_interval)
        super().__exit__(*error)

    def mutate(self, args, *, before, after, timeout=120):
        require(self.fd is not None and self.child is None, 'mutationOwnershipRequired')
        before()
        self._after = after
        expired = False
        def pending():
            nonlocal expired
            expired = True
            self.report('quiescencePending', childPID=self.child.pid, lease=str(self.path),
                        instruction='保持终端开启；不杀子进程，不重试变更，继续持有租约。')
        # File-backed output prevents pipe saturation; the handle cannot escape on Ctrl-C.
        with retain_interrupts(self.report) as interrupts, tempfile.TemporaryFile() as output:
            self.begin('prepareMutation')
            self.child = subprocess.Popen(args, stdout=output, stderr=subprocess.STDOUT,
                                          start_new_session=True, pass_fds=(self.fd,))
            self.record_child(self.child.pid)
            result = wait_for_mutation(self.child, timeout=timeout, pending=pending)
            reported = False
            while True:
                try:
                    self.complete(after)
                    break
                except (Exception, KeyboardInterrupt) as error:
                    if not reported:
                        self.report('systemFactsPending', childPID=self.child.pid,
                                    childExit=result, lease=str(self.path), reason=str(error),
                                    instruction='命令退出不证明系统完成；保留租约并只读复核，禁止重试变更。')
                        reported = True
                    time.sleep(self.retry_interval)
            self.child = None
            require(not interrupts['interrupted'], 'mutationInterrupted')
            require(not expired, 'mutationDeadlineExceeded')
            require(result == 0, 'systemCommandFailed')


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



def preparation_binding(disk, whole):
    identifier = whole['DeviceIdentifier']
    require(disk.get('DeviceIdentifier') == identifier, 'physicalTargetMismatch')
    parts = disk.get('Partitions')
    require(isinstance(parts, list) and len(parts) == 2, 'unexpectedPartitionSet')
    binding = []
    for part in parts:
        device, identity, size = (part.get('DeviceIdentifier'), part.get('DiskUUID'), part.get('Size'))
        require(isinstance(device, str) and re.fullmatch(re.escape(identifier) + r's[0-9]+', device)
                and isinstance(identity, str) and bool(identity) and type(size) is int and size > 0,
                'incompletePartitionIdentity')
        binding.append((device, identity, size, part.get('Content')))
    require(len(set(item[0] for item in binding)) == 2, 'duplicatePartitionIdentity')
    return (identifier, whole['MediaName'], whole['Size'], tuple(binding))


def stable_preparation_target():
    first = fresh_target()
    second = fresh_target()
    require(first == second, 'unstableTargetFacts')
    return second


def fresh_volume(binding, node):
    disk, whole = stable_preparation_target()
    require(preparation_binding(disk, whole) == binding, 'targetBindingChanged')
    check_erased(disk)
    volume = plist(['info', '-plist', node])
    part = next(p for p in disk['Partitions'] if '/dev/' + p['DeviceIdentifier'] == node)
    require(volume.get('DeviceNode') == node and volume.get('ParentWholeDisk') == whole['DeviceIdentifier']
            and volume.get('DiskUUID') == part['DiskUUID'] and volume.get('Size') == part['Size']
            and volume.get('WholeDisk') is False and volume.get('Internal') is False,
            'partitionBindingChanged')
    return volume


def mount_lines():
    first = run(['/sbin/mount']).decode('utf-8', errors='strict').splitlines()
    second = run(['/sbin/mount']).decode('utf-8', errors='strict').splitlines()
    require(first == second and all(line for line in first), 'unstableMountFacts')
    return second


def require_unmounted(binding, node):
    volume = fresh_volume(binding, node)
    require(volume.get('Mounted') is False and volume.get('MountPoint', '') == ''
            and not any(line.startswith(node + ' on ') for line in mount_lines()),
            'partitionStillMountedOrChanged')
    return volume


def require_native_ntfs(binding, node):
    volume = fresh_volume(binding, node)
    point = volume.get('MountPoint')
    require(volume.get('FilesystemType') == 'ntfs' and volume.get('WritableVolume') is False
            and volume.get('Mounted') is True and isinstance(point, str) and point.startswith('/Volumes/'),
            'nativeReadOnlyNTFSMountRequired')
    lines = [line for line in mount_lines() if line.startswith(node + ' on ' + point + ' (')]
    require(len(lines) == 1 and 'ntfs' in lines[0].split(' (', 1)[1].split(', ')
            and bool(os.statvfs(point).f_flag & os.ST_RDONLY), 'nativeMountFactsMismatch')
    require(fresh_volume(binding, node) == volume, 'nativeMountChanged')
    return volume


def prepare_target(owner):
    disk, whole = stable_preparation_target()
    check_original(disk)
    initial = preparation_binding(disk, whole)
    identifier = whole['DeviceIdentifier']
    emit('targetConfirmed', disk=identifier, media=MEDIA_NAME, physicalBytes=PHYSICAL_BYTES)

    def before_erase():
        current, info = stable_preparation_target()
        check_original(current)
        require(preparation_binding(current, info) == initial, 'targetBindingChanged')
    def after_erase():
        current, info = stable_preparation_target()
        require(info['DeviceIdentifier'] == identifier, 'deviceRenumbered')
        efi, data = check_erased(current)
        preparation_binding(current, info)
        require(data.get('VolumeName') == LABEL and data.get('Content') == 'Microsoft Basic Data',
                'erasedLayoutMismatch')
    owner.mutate(['/usr/sbin/diskutil', 'eraseDisk', 'ExFAT', LABEL, 'GPT', identifier],
                 before=before_erase, after=after_erase, timeout=600)
    disk, whole = stable_preparation_target()
    efi, data = check_erased(disk)
    binding = preparation_binding(disk, whole)
    node = '/dev/' + data['DeviceIdentifier']
    emit('diskErased', partition=data['DeviceIdentifier'], partitionBytes=data['Size'])

    if fresh_volume(binding, node).get('MountPoint'):
        owner.mutate(['/usr/sbin/diskutil', 'unmount', node],
                     before=lambda: fresh_volume(binding, node),
                     after=lambda: require_unmounted(binding, node))
    volume = require_unmounted(binding, node)
    offset = volume.get('PartitionMapPartitionOffset')
    require(type(offset) is int and offset > 0 and offset % 512 == 0, 'invalidPartitionOffset')
    def before_format():
        current = require_unmounted(binding, node)
        require(current.get('PartitionMapPartitionOffset') == offset, 'partitionOffsetChanged')
    def after_format():
        current = require_unmounted(binding, node)
        require(current.get('FilesystemType') == 'ntfs' and current.get('VolumeName') == LABEL,
                'ntfsFormatNotObserved')
    owner.mutate([str(MKNTFS), '--quick', '--label', LABEL, '--sector-size', '512',
                  '--partition-start', str(offset // 512), '--heads', '255',
                  '--sectors-per-track', '63', node], before=before_format, after=after_format, timeout=600)
    emit('ntfsFormatted', partition=data['DeviceIdentifier'])

    owner.mutate(['/usr/sbin/diskutil', 'mount', node], before=after_format,
                 after=lambda: require_native_ntfs(binding, node))
    volume = require_native_ntfs(binding, node)
    disk, whole = stable_preparation_target()
    require(preparation_binding(disk, whole) == binding, 'targetBindingChanged')
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


def main():
    try:
        require(os.geteuid() == 0, 'administratorAuthenticationRequired')
        require(hashlib.sha256(MKNTFS.read_bytes()).hexdigest() == MKNTFS_SHA256,
                'mkntfsDigestChanged')
        with PreparationOwner() as owner:
            prepare_target(owner)
        return 0
    except BaseException as error:
        emit('failed', reason=str(error) if isinstance(error, TargetError) else type(error).__name__)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
