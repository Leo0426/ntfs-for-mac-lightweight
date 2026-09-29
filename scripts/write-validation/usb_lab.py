"""One explicitly pinned sacrificial USB experiment; run manually through sudo.

No arbitrary device/options, formatting, recovery, forced unmount, or app integration.
The private target receipt is pinned below; changing it requires reviewing this code.
"""
import argparse
from contextlib import contextmanager
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import traceback
import uuid

# Also support Python isolated mode without importing from the working directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from file_cycle import ValidationError, prepare, cleanup
from manifest_io import load_manifest, save_manifest
from usb_target import TargetError, require, check_target, check_writable_mount
from user_mount_candidate import (candidate, DRIVER_SHA256, MOUNT_UID, MOUNT_GID,
                                  filesystem_identity, unmount_credentials)

BASE = Path(__file__).resolve().parents[2]
TARGET_DIGEST = '8d76fcf2d907e33a0655489a359b99d41e719527b4b3b5163311c0c47b9cc39d'
BUILD = BASE / '.build/dependency-candidates/ntfs-3g-build'
# No 'quiet': the driver's own error reports go to the per-run mount log.
# no_def_opts also cancels NTFS-3G's default `silent`; restore it so chown of new entries to
# the file-operation user does not fail against the root-started driver's context uid.
OPTIONS = 'rw,no_def_opts,silent,backend=fskit,norecover,no_detach,local'
ARTIFACTS = {
    BUILD / 'src/ntfs-3g': '95ea1bb325cfc39f0c76999e4d98049bdd58f51929e0152432828d4d3cd4d2fc',
    BUILD / 'src/ntfs-3g.probe': 'c917ddbf3c2350513d534139ef38dbb55b6c7a52957832e4744e3f77e82a625b',
    Path('/usr/local/lib/libfuse.2.dylib'): '7f8284463379f48034e38913804920719fb2c13a42e04027533fd1d19ff8bb42',
}


def emit(stage, **values):
    print(json.dumps({'stage': stage, **values}, sort_keys=True), flush=True)


class SystemOperationError(TargetError):
    def __init__(self, operation, error):
        super().__init__('systemCallFailed')
        self.operation = operation
        self.errno = error.errno


@contextmanager
def system_operation(operation):
    try:
        yield
    except OSError as error:
        raise SystemOperationError(operation, error) from error


def failure_details(error, operation):
    details = {'reason': str(error) if isinstance(error, (TargetError, ValidationError))
               else type(error).__name__,
               'operation': error.operation if isinstance(error, SystemOperationError) else operation}
    if isinstance(error, (OSError, SystemOperationError)):
        number = error.errno if type(error.errno) is int else None
        details.update(errno=number, errnoName=errno.errorcode.get(number, 'unknown'))
    frames = traceback.extract_tb(error.__traceback__)
    if frames:
        # File basename, function and line only: never directory paths or error text.
        last = frames[-1]
        details['failedAt'] = f'{Path(last.filename).name}:{last.name}:{last.lineno}'
    return details


def query(args, timeout=20, as_mount_user=False):
    result = subprocess.run(args, capture_output=True, timeout=timeout,
                            **(unmount_credentials() if as_mount_user else {}))
    require(result.returncode == 0 and len(result.stdout) <= 1024**2, 'systemQueryFailed')
    return result.stdout


def plist(args):
    value = plistlib.loads(query(['/usr/sbin/diskutil', *args]))
    require(isinstance(value, dict), 'invalidSystemFacts')
    return value


def mounts():
    first = query(['/sbin/mount']).decode('utf8')
    require(first == query(['/sbin/mount']).decode('utf8'), 'mountTableChanged')
    return first.splitlines()


def verify_driver_identity(process):
    require(process is not None and process.poll() is None, 'driverNotRunning')
    ids = query(['/bin/ps', '-p', str(process.pid), '-o', 'ruid=,uid=,rgid=,gid=']).split()
    require(ids == [str(value).encode() for value in (MOUNT_UID, MOUNT_UID, MOUNT_GID, MOUNT_GID)],
            'driverIdentityNotDropped')
    require(process.poll() is None, 'driverNotRunning')


def verify_fskit_binding(process, node, source):
    # The FSKit mount source is a 4 KiB virtual placeholder disk; bind the mount to the
    # physical partition by proving the owned driver process holds that exact device open.
    facts = plist(['info', '-plist', source])
    require(facts.get('DeviceNode') == source and facts.get('WholeDisk') is True
            and facts.get('VirtualOrPhysical') == 'Virtual'
            and facts.get('BusProtocol') == 'Disk Image' and facts.get('TotalSize') == 4096,
            'mountSourceNotFSKitPlaceholder')
    held = subprocess.run(['/usr/sbin/lsof', '-a', '-p', str(process.pid), '-Fn', node],
                          capture_output=True, timeout=20)
    fields = held.stdout.decode('utf8', 'replace').splitlines() if held.returncode == 0 else []
    require('p' + str(process.pid) in fields and 'n' + node in fields, 'driverNotHoldingTarget')


def fresh_mountpoint():
    root = Path('/Volumes/NTFSLiteUSB-' + uuid.uuid4().hex)
    require(not os.path.lexists(root), 'mountpointAlreadyExists')
    return root


def remove_stale_mountpoint(root):
    # macOS 27 FSKit leaves the empty mountpoint after a standard unmount. Remove only
    # an empty real directory; anything else stays for inspection.
    try:
        info = os.lstat(root)
    except FileNotFoundError:
        return
    require(stat.S_ISDIR(info.st_mode), 'staleMountpointNotDirectory')
    try:
        os.rmdir(root)
    except OSError as error:
        raise TargetError('staleMountpointNotEmpty') from error


def private_target():
    path = BASE / '.build/write-validation/approved-usb-target.json'
    require(path.resolve(strict=True) == path, 'targetReceiptLink')
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_size <= 4096,
                'invalidTargetReceipt')
        data = os.read(descriptor, 4097)
        require(hashlib.sha256(data).hexdigest() == TARGET_DIGEST, 'targetReceiptMismatch')
        return json.loads(data)
    finally:
        os.close(descriptor)


def snapshot(expected):
    all_disks = plist(['list', '-plist'])['AllDisksAndPartitions']
    candidates = [(disk, part) for disk in all_disks for part in disk.get('Partitions', [])
                  if part.get('DiskUUID') == expected['partitionUUID']]
    require(len(candidates) == 1, 'targetAbsentOrAmbiguous')
    disk, part = candidates[0]
    whole = plist(['info', '-plist', disk['DeviceIdentifier']])
    volume = plist(['info', '-plist', part['DeviceIdentifier']])
    checked_disk, node = check_target(expected, whole, volume, disk.get('Partitions', []))
    return {'disk': checked_disk, 'node': node, 'mountpoint': volume.get('MountPoint', ''),
            'filesystem': volume.get('FilesystemType'), 'writable': volume.get('WritableVolume'),
            'whole': whole, 'volume': volume, 'partitions': disk['Partitions']}


def stable_snapshot(expected):
    first = snapshot(expected)
    require(first == snapshot(expected), 'targetFactsChanged')
    return first


def block_device_info(node, expected_rdev=None):
    # diskutil's /dev/disk… nodes are block devices on macOS; /dev/rdisk… are raw character devices.
    info = os.lstat(node)
    require(stat.S_ISBLK(info.st_mode), 'notBlockDevice')
    require(expected_rdev is None or info.st_rdev == expected_rdev, 'deviceChanged')
    return info


def device_identity(info):
    return info.st_dev, info.st_ino, info.st_rdev, stat.S_IFMT(info.st_mode)


def boot_device_pair(node, expected_rdev):
    require(re.fullmatch(r'/dev/disk[0-9]+s[0-9]+', node) is not None, 'invalidBlockDevicePath')
    block = block_device_info(node, expected_rdev)
    # macOS rejects opening a mounted block device even read-only. Read its paired raw node;
    # the block node remains the diskutil / driver / mount-table identity.
    raw_node = '/dev/r' + node[5:]
    raw = os.lstat(raw_node)
    require(stat.S_ISCHR(raw.st_mode), 'notRawCharacterDevice')
    require(raw.st_rdev == block.st_rdev and raw.st_dev == block.st_dev, 'devicePairMismatch')
    return raw_node, block, raw


def dependencies():
    for path, digest in ARTIFACTS.items():
        require(path.resolve(strict=True) == path and stat.S_ISREG(path.lstat().st_mode)
                and path.lstat().st_nlink == 1 and not path.lstat().st_mode & 0o022,
                'dependencyLocationOrModeChanged')
        require(hashlib.sha256(path.read_bytes()).hexdigest() == digest, 'dependencyDigestChanged')
    app = Path('/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app')
    paths = [app, Path('/usr/local/lib/libfuse.2.dylib')]
    paths += [app / ('Contents/Extensions/' + identifier + '.appex') for identifier in
              ['io.macfuse.app.fsmodule.macfuse', 'io.macfuse.app.fsmodule.macfuse-local']]
    for path in paths:
        query(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)])
        signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(path)],
                                   capture_output=True, timeout=20)
        require(signature.returncode == 0 and b'TeamIdentifier=3T5GSNBU6W\n' in signature.stderr,
                'dependencySignerChanged')


def run_preflight():
    # Everything --run needs before its first disk mutation that is checkable without
    # root: the pinned v2 driver and the file-check identity switch.
    candidate()
    with filesystem_identity():
        pass


def record(lab, stage, **values):
    # A failure must reach the terminal even if the evidence directory is unwritable.
    try:
        lab.journal(stage, **values)
    except BaseException as error:
        emit(stage, **values, evidenceDirectory=str(lab.folder), journalRecorded=False,
             journalError=failure_details(error, 'journalWrite'))


def wait_for_mutation(process):
    try:
        return process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        emit('quiescencePending', instruction='保持终端开启；命令尚未退出，不会继续下一步。')
        # Do not kill a mutation or release its lease merely because it timed out.
        return process.wait()


@contextmanager
def defer_interrupts():
    # Preserve the child handle before an interrupt can unwind the caller.
    # Use handlers, not a blocked mask that a child would inherit across exec.
    pending = False
    def defer(_signum, _frame):
        nonlocal pending
        pending = True
    previous = {item: signal.getsignal(item) for item in [signal.SIGINT, signal.SIGTERM]}
    try:
        for item in previous:
            signal.signal(item, defer)
        yield
    finally:
        for item, handler in previous.items():
            signal.signal(item, handler)
        if pending:
            raise InterruptedError('interruptedDuringProcessStart')


class USBLab:
    def __init__(self, expected):
        run_preflight()
        require(not any('(macfuse,' in line or 'NTFSLite' in line for line in mounts()),
                'existingExperimentMount')
        existing = subprocess.run(['/usr/bin/pgrep', '-x', 'ntfs-3g'], capture_output=True, timeout=10)
        require(existing.returncode == 1, 'existingDriverOrQueryFailed')
        self.expected = expected
        self.initial = stable_snapshot(expected)
        self.node, self.disk = self.initial['node'], self.initial['disk']
        self.native_root = self.initial['mountpoint']
        require(self.native_root.startswith('/Volumes/') and self.initial['filesystem'] == 'ntfs'
                and self.initial['writable'] is False, 'initialNativeReadOnlyMountRequired')
        require(Path(self.native_root).resolve(strict=True) == Path(self.native_root), 'nativeMountpointLink')
        self.device_rdev = block_device_info(self.node).st_rdev
        self.boot = self.read_boot()
        self.root = fresh_mountpoint()
        parent = BASE / '.build/write-validation'
        require(parent.resolve(strict=True) == parent, 'evidenceParentLink')
        require(parent.stat().st_dev != Path(self.native_root).stat().st_dev, 'evidenceOnTargetVolume')
        self.folder = Path(tempfile.mkdtemp(prefix='usb-run-', dir=parent))
        self.owner = BASE.stat().st_uid
        os.chown(self.folder, self.owner, -1)
        self.process = None
        self.pending_mutation = None
        self.mount_device = None
        self.mount_source = None
        self.counter = 0
        self.manifest = None
        self.remount_verified = False
        self.journal('started', physicalBytes=expected['physicalBytes'], windowsVerified=False,
                     driverSHA256=DRIVER_SHA256, mountUID=MOUNT_UID)

    def journal(self, stage, **values):
        self.counter += 1
        path = self.folder / f'{self.counter:02}-{stage}.json'
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, 'w') as handle:
            json.dump({'stage': stage, **values}, handle, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
            os.fchown(handle.fileno(), self.owner, -1)
        emit(stage, evidenceDirectory=str(self.folder), **values)

    def read_boot(self):
        with system_operation('bootDeviceMetadata'):
            raw_node, block, before = boot_device_pair(self.node, self.device_rdev)
        with system_operation('bootDeviceOpen'):
            fd = os.open(raw_node, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            with system_operation('bootDescriptorMetadata'):
                opened = os.fstat(fd)
            require(device_identity(opened) == device_identity(before), 'deviceChanged')
            with system_operation('bootSectorRead'):
                boot = os.read(fd, 512)
            require(len(boot) == 512 and boot[3:11] == b'NTFS    ' and boot[510:] == b'\x55\xaa'
                    and any(boot[72:80]), 'invalidNTFSBootSector')
            with system_operation('bootDeviceRecheck'):
                _, current_block, current = boot_device_pair(self.node, self.device_rdev)
                require(device_identity(current_block) == device_identity(block)
                        and device_identity(current) == device_identity(opened)
                        and device_identity(os.fstat(fd)) == device_identity(opened), 'deviceChanged')
            return boot
        finally:
            with system_operation('bootDeviceClose'):
                os.close(fd)

    def guard(self, mode):
        facts = stable_snapshot(self.expected)
        require(facts['node'] == self.node and facts['disk'] == self.disk, 'deviceRenumberedDuringRun')
        require(self.read_boot() == self.boot, 'bootIdentityChanged')
        lines = mounts()
        if mode == 'native':
            require(facts['mountpoint'] == self.native_root and facts['filesystem'] == 'ntfs'
                    and facts['writable'] is False, 'nativeMountChanged')
            selected = [line for line in lines if ' on ' + self.native_root + ' ' in line]
            require(len(selected) == 1 and selected[0].startswith(self.node + ' on ')
                    and '(ntfs, ' in selected[0] and 'read-only' in selected[0], 'nativeMountChanged')
        elif mode == 'unmounted':
            require(facts['mountpoint'] == '' and not any(line.startswith(self.node + ' on ')
                    or ' on ' + str(self.root) + ' ' in line for line in lines), 'volumeStillMounted')
        else:
            # diskutil does not attribute FSKit mounts to the partition; it must show none.
            require(facts['mountpoint'] == '', 'nativeMountPresent')
            verify_driver_identity(self.process)
            _, source = check_writable_mount(lines, self.node, str(self.root))
            verify_fskit_binding(self.process, self.node, source)
            require(self.mount_source in (None, source), 'mountInstanceChanged')
            verify_driver_identity(self.process)
            with filesystem_identity():
                require(self.root.resolve(strict=True) == self.root
                        and self.root.stat().st_dev != self.root.parent.stat().st_dev
                        and not os.statvfs(self.root).f_flag & os.ST_RDONLY, 'mountNotWritable')
                if self.mount_device is not None:
                    require(self.root.stat().st_dev == self.mount_device, 'mountInstanceChanged')
        return lines

    def mutation(self, args, as_mount_user=False):
        with (self.folder / f'command-{self.counter:02}.log').open('xb') as log:
            os.fchmod(log.fileno(), 0o600)
            os.fchown(log.fileno(), self.owner, -1)
            with defer_interrupts():
                self.pending_mutation = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                                                         restore_signals=True,
                                                         **(unmount_credentials() if as_mount_user else {}))
            result = wait_for_mutation(self.pending_mutation)
            self.pending_mutation = None
            require(result == 0, 'diskCommandFailed')

    def unmount_native(self):
        self.guard('native')
        self.mutation(['/usr/sbin/diskutil', 'unmount', self.node])
        self.guard('unmounted')
        self.journal('nativeUnmountVerified')

    def health(self):
        self.guard('unmounted')
        query([str(BUILD / 'src/ntfs-3g.probe'), '--readwrite', self.node])

    def mount(self):
        dependencies()
        driver = candidate()
        self.health()
        self.root = fresh_mountpoint()
        self.guard('unmounted')
        with (self.folder / f'mount-{self.counter:02}.log').open('xb') as log:
            os.fchmod(log.fileno(), 0o600)
            os.fchown(log.fileno(), self.owner, -1)
            with defer_interrupts():
                self.process = subprocess.Popen([str(driver), self.node,
                                                str(self.root), '-o', OPTIONS], stdout=log,
                                               stderr=subprocess.STDOUT, restore_signals=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            require(self.process.poll() is None, 'mountProcessExited')
            lines = mounts()
            if any(' on ' + str(self.root) + ' ' in line for line in lines):
                self.guard('writable')
                with filesystem_identity():
                    self.mount_device = self.root.stat().st_dev
                line, self.mount_source = check_writable_mount(mounts(), self.node, str(self.root))
                self.guard('writable')
                self.journal('writableMountVerified', mountLine=line)
                return
            time.sleep(0.25)
        raise TargetError('mountNotObservedBeforeDeadline')

    def check_cleanup(self):
        self.guard('writable')
        with filesystem_identity():
            small = prepare(self.root)
        self.guard('writable')
        with filesystem_identity():
            cleanup(self.root, small)
        self.guard('writable')
        self.journal('cleanupVerified', checks=small['checks'])

    def prepare(self):
        self.guard('writable')
        with filesystem_identity():
            require(self.folder.stat().st_dev != self.root.stat().st_dev, 'evidenceOnTargetVolume')
        emit('preparingWindowsDataset', largeFileBytes=4 * 1024**3 + 1)
        with filesystem_identity():
            self.manifest = prepare(self.root, large_bytes=4 * 1024**3 + 1,
                                    progress=lambda name: emit('fileChecked', file=name))
        self.guard('writable')
        manifest_path = self.folder / 'manifest.json'
        save_manifest(manifest_path, self.manifest)
        os.chown(manifest_path, self.owner, -1)
        self.journal('fileChecksPassed', checks=self.manifest['checks'], windowsVerified=False)

    def unmount(self):
        self.guard('writable')
        self.mutation(['/sbin/umount', str(self.root)], as_mount_user=True)
        self.guard('unmounted')
        require(wait_for_mutation(self.process) == 0, 'driverExitFailed')
        self.process = None
        self.mount_device = None
        self.mount_source = None
        remove_stale_mountpoint(self.root)
        self.health()
        self.journal('unmountVerified')

    def verify(self):
        self.guard('writable')
        require(load_manifest(self.folder / 'manifest.json') == self.manifest, 'savedExpectationsChanged')
        result = query([sys.executable, '-I', '-S', str(BASE / 'scripts/write-validation/verify_files.py'),
                        '--root', str(self.root), '--manifest', str(self.folder / 'manifest.json')],
                       timeout=600, as_mount_user=True)
        report = json.loads(result)
        require(report.get('status') == 'fileChecksPassed', 'independentReadbackFailed')
        self.guard('writable')
        require(load_manifest(self.folder / 'manifest.json') == self.manifest, 'savedExpectationsChanged')
        self.remount_verified = True
        self.journal('remountReadbackVerified', retainedFiles=report['retainedFiles'],
                     deletedEntries=report['deletedEntries'], windowsVerified=False)

    def finish(self):
        self.guard('unmounted')
        require(self.remount_verified and self.process is None, 'incompleteCycle')
        self.journal('localChecksPassed', remountVerified=True, windowsVerified=False,
                     testDirectory=self.manifest['directory'], retainedForWindows=True,
                     volumeUnmounted=True, safeToRemoveVerified=False)

    def stop_after_failure(self):
        if self.pending_mutation is not None:
            wait_for_mutation(self.pending_mutation)
        if self.process is not None and self.process.poll() is None:
            try:
                if any(' on ' + str(self.root) + ' ' in line for line in mounts()):
                    # Only the same freshly verified writable target can be closed here.
                    # No file cleanup or success claim follows a failed file operation.
                    self.unmount()
            except BaseException as error:
                emit('inspectionRequired', **failure_details(error, 'failedRunUnmount'),
                     mountpoint=str(self.root),
                     instruction='保持终端开启；挂载归属或标准卸载尚未确认，保留驱动等待检查。')
            if self.process is not None:
                wait_for_mutation(self.process)
        # Never terminate a driver that might still own a live FSKit connection.


def complete_cycle(lab):
    lab.unmount_native()
    lab.mount()
    lab.check_cleanup()
    lab.prepare()
    lab.unmount()
    lab.mount()
    lab.verify()
    lab.unmount()
    lab.finish()


def probe_device(expected, facts):
    # Bypass all lab initialization, evidence-directory creation and mutation methods.
    reader = USBLab.__new__(USBLab)
    reader.node = facts['node']
    reader.device_rdev = block_device_info(reader.node).st_rdev
    before = mounts()
    first = reader.read_boot()
    require(first == reader.read_boot(), 'bootIdentityChanged')
    require(stable_snapshot(expected) == facts and mounts() == before, 'targetFactsChanged')
    return len(first)


def main():
    parser = argparse.ArgumentParser(description='固定目标的独立 USB 实验；成功后保留 Windows 复核数据并保持卷卸载。')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--inspect', action='store_true', help='只读核对目标、依赖及当前驱动候选，不访问原始设备或执行磁盘变更')
    mode.add_argument('--probe-device', action='store_true', help='只读设备诊断：读取并核对启动扇区，不卸载或写入')
    mode.add_argument('--run', action='store_true', help='需要 sudo；执行已授权目标的写删与重挂载闭环')
    args = parser.parse_args()
    lab = None
    lease = None
    operation = 'targetReceiptRead'
    try:
        expected = private_target()
        operation = 'targetQuery'
        facts = stable_snapshot(expected)
        operation = 'deviceMetadata'
        block_device_info(facts['node'])
        operation = 'dependencyCheck'
        dependencies()
        operation = 'candidateCheck'
        run_preflight()
        if args.inspect:
            emit('targetMatched', media=expected['mediaName'], physicalBytes=expected['physicalBytes'],
                 partitionBytes=expected['partitionBytes'], currentlyWritable=facts['writable'],
                 deviceNodeType='block', mountCandidateVerified=True, driverSHA256=DRIVER_SHA256,
                 administratorRequired=os.geteuid() != 0, diskMutationsPerformed=False)
            return 0
        operation = 'administratorCheck'
        require(os.geteuid() == 0, 'administratorAuthenticationRequired')
        if args.probe_device:
            operation = 'deviceProbe'
            count = probe_device(expected, facts)
            emit('deviceReadVerified', bootBytes=count, diskMutationsPerformed=False)
            return 0
        # Shared among this experiment's invocations; root-owned and protected from replacement.
        lease_path = '/private/var/run/ntfslite-usb-lab.lock'
        operation = 'leaseOpen'
        lease = os.open(lease_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        operation = 'leaseMetadata'
        info = os.fstat(lease)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1
                and info.st_mode & 0o777 == 0o600, 'unsafeLeaseFile')
        operation = 'leaseAcquire'
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        def interrupted(_signum, _frame):
            raise InterruptedError('interrupted')
        signal.signal(signal.SIGTERM, interrupted)
        operation = 'initializeExperiment'
        lab = USBLab(expected)
        operation = 'fileCycle'
        complete_cycle(lab)
        return 0
    except BaseException as error:
        details = failure_details(error, operation)
        if lab is not None:
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            # Record the original failure first: the stop below may wait indefinitely on a driver.
            record(lab, 'failed', **details, windowsVerified=False, inspectResidualMountState=True)
            lab.stop_after_failure()
            record(lab, 'failureHandlingFinished', windowsVerified=False, inspectResidualMountState=True)
        else:
            emit('blocked', **details, diskMutationsPerformed=False)
        return 1
    finally:
        if lease is not None:
            os.close(lease)


if __name__ == '__main__':
    raise SystemExit(main())
