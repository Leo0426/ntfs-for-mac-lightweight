"""Fixed disposable-image FSKit probe. Never opens or mutates a physical device."""
import argparse
from contextlib import nullcontext
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
from usb_lab import (BASE, BUILD, dependencies, mounts, query, plist, require,
                     defer_interrupts, wait_for_mutation, emit, failure_details,
                     private_target, stable_snapshot, verify_driver_identity)
from usb_target import TargetError
from user_mount_candidate import (candidate, DRIVER, DRIVER_SHA256, MOUNT_UID, MOUNT_GID,
                                  filesystem_identity, unmount_credentials)

OPTIONS = 'rw,no_def_opts,backend=fskit,norecover,no_detach,local,quiet'
SEED = BASE / '.build/write-validation/2e5ad20605bb4a2badc63df70a2b256b.ntfs'
SEED_DIGEST = '835e54c912d82eac3cf3a6beaf75f73e379191d0e142b950fc2c7a49ba69fc13'


def image_identity(path):
    info = path.lstat()
    require(path.resolve(strict=True) == path and stat.S_ISREG(info.st_mode)
            and info.st_nlink == 1 and not info.st_mode & 0o022, 'invalidProbeImage')
    return info.st_dev, info.st_ino, info.st_uid, info.st_size


def selected_mount(root):
    selected = [line for line in mounts() if ' on ' + str(root) + ' ' in line]
    require(len(selected) <= 1, 'ambiguousProbeMount')
    return selected[0] if selected else None


def owned_mount(process, image, identity, root, user_mount=False):
    require(image_identity(image) == identity, 'probeImageChanged')
    require(process.poll() is None, 'probeDriverExited')
    line = selected_mount(root)
    require(line is not None, 'probeMountAbsent')
    with filesystem_identity() if user_mount else nullcontext():
        require(root.resolve(strict=True) == root and stat.S_ISDIR(root.lstat().st_mode),
                'probeMountRootChanged')
    source, suffix = line.split(' on ', 1)
    require(re.fullmatch(r'/dev/disk[0-9]+', source) is not None
            and suffix.startswith(str(root) + ' (macfuse, ')
            and {'local', 'fskit'}.issubset(set(suffix.rsplit(' (', 1)[1].rstrip(')').split(', '))),
            'unexpectedProbeMount')
    facts = plist(['info', '-plist', source])
    require(facts.get('DeviceNode') == source and facts.get('WholeDisk') is True
            and facts.get('VirtualOrPhysical') == 'Virtual'
            and facts.get('BusProtocol') == 'Disk Image' and facts.get('TotalSize') == 4096,
            'probeSourceNotVirtualDevice')
    held = query(['/usr/sbin/lsof', '-a', '-p', str(process.pid), '-Fn', str(image)]).decode().splitlines()
    require('p' + str(process.pid) in held and 'n' + str(image) in held, 'probeBackingFileNotHeld')
    require(selected_mount(root) == line and process.poll() is None, 'probeMountChanged')
    return line


def probe_mount(image, root, log_path, user_mount=False):
    """Keep the owned driver alive while validating and normally unmounting its image."""
    identity = image_identity(image)
    require(not any('(macfuse,' in line or 'NTFSLite' in line for line in mounts()),
            'existingExperimentMount')
    with log_path.open('xb') as log:
        os.fchmod(log.fileno(), 0o600)
        if os.geteuid() == 0:
            os.fchown(log.fileno(), image.lstat().st_uid, -1)
        process = None
        try:
            with defer_interrupts():
                driver = DRIVER if user_mount else BUILD / 'src/ntfs-3g'
                process = subprocess.Popen([str(driver), str(image), str(root), '-o', OPTIONS],
                                           stdout=log, stderr=subprocess.STDOUT, restore_signals=True)
            deadline = time.monotonic() + 20
            while selected_mount(root) is None:
                require(process.poll() is None, 'mountProcessExited')
                require(time.monotonic() < deadline, 'mountNotObservedBeforeDeadline')
                time.sleep(.25)
            line = owned_mount(process, image, identity, root, user_mount)
            if user_mount:
                verify_driver_identity(process)
            require('read-only' not in line, 'mountNotWritable')
            with filesystem_identity() if user_mount else nullcontext():
                require(root.resolve(strict=True) == root
                        and root.stat().st_dev != root.parent.stat().st_dev
                        and not os.statvfs(root).f_flag & os.ST_RDONLY, 'mountNotWritable')
            return line
        finally:
            if process is not None:
                # A validation error must not tear down the driver before normal unmount.
                # Defer interruptions through child-handle capture AND all cleanup waits.
                with defer_interrupts():
                    try:
                        closed = selected_mount(root) is not None
                        if closed:
                            owned_mount(process, image, identity, root, user_mount)
                            unmount = subprocess.Popen(['/sbin/umount', str(root)], stdout=log,
                                                       stderr=subprocess.STDOUT, restore_signals=True,
                                                       **(unmount_credentials() if user_mount else {}))
                            require(wait_for_mutation(unmount) == 0, 'probeUnmountFailed')
                            require(selected_mount(root) is None, 'probeResidualMount')
                        status = wait_for_mutation(process)
                        require(not closed or status == 0, 'probeDriverExitFailed')
                        require(selected_mount(root) is None, 'probeResidualMount')
                    except BaseException:
                        if process.poll() is None:
                            emit('inspectionRequired', instruction='镜像收尾未完成；保持终端开启，驱动将继续保留。')
                            # No termination request: a live driver may still be needed to unmount.
                            wait_for_mutation(process)
                        raise


def seed_bytes():
    """Read the retained, approved disposable seed without ever opening it writable."""
    identity = image_identity(SEED)
    require(identity[2] == BASE.stat().st_uid and identity[3] == 128 * 1024**2,
            'probeSeedIdentityMismatch')
    descriptor = os.open(SEED, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as source:
        before = os.fstat(source.fileno())
        require((before.st_dev, before.st_ino, before.st_uid, before.st_size) == identity,
                'probeSeedChanged')
        data = source.read(128 * 1024**2 + 1)
        after = os.fstat(source.fileno())
        require(before == after and image_identity(SEED) == identity, 'probeSeedChanged')
    require(len(data) == 128 * 1024**2 and hashlib.sha256(data).hexdigest() == SEED_DIGEST,
            'probeSeedDigestChanged')
    return data


def main():
    parser = argparse.ArgumentParser(description='固定一次性镜像的 FSKit local 挂载对照；不卸载或写入物理 U 盘。')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--inspect', action='store_true', help='只读核对候选、固定镜像与现场')
    mode.add_argument('--run', action='store_true', help='在当前用户身份下对固定镜像的新副本挂载并标准卸载')
    parser.add_argument('--user-mount-candidate', action='store_true',
                        help='验证固定的设备打开后永久降权候选；仅用于独立镜像对照')
    args = parser.parse_args()
    folder = None
    lease = None
    report = None
    operation = 'preflight'
    owner = BASE.stat().st_uid
    try:
        require(os.geteuid() in (0, owner), 'unexpectedCaller')
        dependencies()
        if args.user_mount_candidate:
            candidate()
            operation = 'supervisorIdentityPreflight'
            with filesystem_identity():
                pass
            operation = 'preflight'
        require(not any('(macfuse,' in line or 'NTFSLite' in line for line in mounts()),
                'existingExperimentMount')
        drivers = subprocess.run(['/usr/bin/pgrep', '-x', 'ntfs-3g'], capture_output=True, timeout=10)
        require(drivers.returncode == 1, 'existingDriverOrQueryFailed')
        expected = private_target()
        usb_before = stable_snapshot(expected)
        before_mounts = mounts()
        seed = seed_bytes()
        if args.inspect:
            emit('mountContextPreflightPassed', effectiveUID=os.geteuid(), sourceImageSHA256=SEED_DIGEST,
                 userMountCandidate=args.user_mount_candidate,
                 physicalDeviceMutationsPerformed=False, imageMountAttempted=False)
            return 0
        parent = BASE / '.build/write-validation'
        require(parent.resolve(strict=True) == parent, 'evidenceParentLink')
        operation = 'probeLease'
        # Shared between root/user invocations of this image-only experiment.
        lease_path = parent / 'context-probe.lock'
        try:
            lease = os.open(lease_path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
            if os.geteuid() == 0:
                os.fchown(lease, owner, -1)
        except FileExistsError:
            lease = os.open(lease_path, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
        info = os.fstat(lease)
        require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1
                and info.st_uid == owner and info.st_mode & 0o777 == 0o600, 'unsafeProbeLease')
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        folder = Path(tempfile.mkdtemp(prefix='context-probe-', dir=parent))
        if os.geteuid() == 0:
            os.chown(folder, owner, -1)
        operation = 'createDisposableCopy'
        image = folder / 'image.ntfs'
        with image.open('xb') as destination:
            os.fchmod(destination.fileno(), 0o600)
            destination.write(seed)
            destination.flush()
            os.fsync(destination.fileno())
            if os.geteuid() == 0:
                os.fchown(destination.fileno(), owner, -1)
        del seed
        require(hashlib.sha256(image.read_bytes()).hexdigest() == SEED_DIGEST, 'probeCopyMismatch')
        root = Path('/Volumes/NTFSLiteContext-' + uuid.uuid4().hex[:12])
        require(not os.path.lexists(root), 'mountpointAlreadyExists')
        query([str(BUILD / 'src/ntfs-3g.probe'), '--readwrite', str(image)])
        dependencies()
        if args.user_mount_candidate:
            candidate()
        require(stable_snapshot(expected) == usb_before and mounts() == before_mounts, 'systemFactsChanged')
        def interrupted(_signum, _frame):
            raise InterruptedError('probeInterrupted')
        signal.signal(signal.SIGTERM, interrupted)
        operation = 'imageMountAndUnmount'
        emit('mountContextProbeStarted', effectiveUID=os.geteuid(), evidenceDirectory=str(folder),
             userMountCandidate=args.user_mount_candidate,
             physicalDeviceMutationsPerformed=False)
        line = probe_mount(image, root, folder / 'mount.log', user_mount=args.user_mount_candidate)
        operation = 'postUnmountCheck'
        query([str(BUILD / 'src/ntfs-3g.probe'), '--readwrite', str(image)])
        require(stable_snapshot(expected) == usb_before and mounts() == before_mounts, 'systemFactsChanged')
        report = dict(stage='mountContextVerified', effectiveUID=os.geteuid(), sourceImageSHA256=SEED_DIGEST,
                      mountLine=line, standardUnmountVerified=True, driverExitVerified=True,
                      physicalDeviceMutationsPerformed=False, usbWriteVerified=False, windowsVerified=False)
        if args.user_mount_candidate:
            report.update(userMountCandidate=True, driverSHA256=DRIVER_SHA256,
                          driverRealAndEffectiveUID=MOUNT_UID, driverRealAndEffectiveGID=MOUNT_GID)
        return 0
    except BaseException as error:
        report = dict(stage='failed', effectiveUID=os.geteuid(), **failure_details(error, operation),
                      physicalDeviceMutationsPerformed=False, usbWriteVerified=False, windowsVerified=False)
        return 1
    finally:
        if report is not None:
            report['userMountCandidate'] = args.user_mount_candidate
            if folder is not None:
                report['evidenceDirectory'] = str(folder)
                with (folder / 'result.json').open('x') as output:
                    os.fchmod(output.fileno(), 0o600)
                    json.dump(report, output, sort_keys=True)
                    output.write('\n')
                    output.flush()
                    os.fsync(output.fileno())
                    if os.geteuid() == 0:
                        os.fchown(output.fileno(), owner, -1)
            print(json.dumps(report, sort_keys=True), flush=True)
        if lease is not None:
            os.close(lease)


if __name__ == '__main__':
    raise SystemExit(main())
