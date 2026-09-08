"""File semantics checks. The caller must independently authorize the volume.

Only an exclusively created per-run directory is modified. No mounting,
privilege changes, recursive cleanup, or Windows-success claims live here.
"""
import errno
import hashlib
import os
from pathlib import Path
import re
import stat
import uuid


class ValidationError(Exception):
    pass


BLOCK = bytes(range(256)) * 4096
NAMES = {'empty.bin', 'overwrite.bin', 'append.bin', 'renamed.bin',
         '中文 空格 🧪.bin', 'large.bin'} | {f'tiny-{n:02}.bin' for n in range(1, 17)}
DELETED = ['before-rename.bin', 'replace-source.bin', 'deleted.bin', 'directory-before', 'directory-after', 'nonempty']


def identity(info):
    return info.st_dev, info.st_ino


class Workspace:
    def __init__(self, root, name, create=False):
        self.root = Path(root).absolute()
        if self.root.resolve(strict=True) != self.root or not re.fullmatch(r'ntfslite-check-[0-9a-f]{32}', name):
            raise ValidationError('unsafeRootOrRunID')
        self.name = name
        self.root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.fd = None
        try:
            if create:
                os.mkdir(name, 0o700, dir_fd=self.root_fd)
            self.fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.root_fd)
            self.check()
        except BaseException:
            self.close()
            raise

    def check(self):
        base, current = os.fstat(self.root_fd), os.fstat(self.fd)
        if (identity(os.stat(self.root, follow_symlinks=False)) != identity(base)
                or identity(os.stat(self.name, dir_fd=self.root_fd, follow_symlinks=False)) != identity(current)
                or current.st_dev != base.st_dev):
            raise ValidationError('workspaceReplaced')

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        os.close(self.root_fd)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def open_file(self, name, flags):
        self.check()
        descriptor = os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=self.fd)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_dev != os.fstat(self.fd).st_dev:
            os.close(descriptor)
            raise ValidationError('unsafeFile')
        return descriptor

    def write(self, name, chunks, mode='create'):
        flags = os.O_WRONLY | (os.O_CREAT | os.O_EXCL if mode == 'create' else 0)
        if mode == 'append':
            flags |= os.O_APPEND
        fd = self.open_file(name, flags)
        try:
            if mode == 'overwrite':
                os.ftruncate(fd, 0)
            for chunk in chunks:
                remaining = memoryview(chunk)
                while remaining:
                    written = os.write(fd, remaining)
                    if written <= 0:
                        raise ValidationError('shortWrite')
                    remaining = remaining[written:]
            os.fsync(fd)
        finally:
            os.close(fd)

    def verify_file(self, name, expected):
        fd = self.open_file(name, os.O_RDONLY)
        try:
            before = os.fstat(fd)
            if before.st_size != expected['bytes']:
                raise ValidationError('lengthMismatch')
            digest, total = hashlib.sha256(), 0
            while chunk := os.read(fd, len(BLOCK)):
                total += len(chunk)
                if total > expected['bytes']:
                    raise ValidationError('lengthMismatch')
                digest.update(chunk)
            after = os.fstat(fd)
            named = os.stat(name, dir_fd=self.fd, follow_symlinks=False)
            if (identity(named) != identity(before) or not stat.S_ISREG(named.st_mode)
                    or named.st_nlink != 1 or after.st_nlink != 1
                    or (named.st_size, named.st_mtime_ns) != (after.st_size, after.st_mtime_ns)):
                raise ValidationError('fileReplacedDuringRead')
            if (total != expected['bytes'] or digest.hexdigest() != expected['sha256']
                    or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns)):
                raise ValidationError('contentMismatch')
        finally:
            os.close(fd)
        self.check()

    def absent(self, name):
        self.check()
        try:
            os.stat(name, dir_fd=self.fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise ValidationError('entryStillPresent')


def expectation(data):
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


def prepare(root, large_bytes=0, run_id=None, progress=lambda _: None):
    if type(large_bytes) is not int or not 0 <= large_bytes <= 4 * 1024**3 + 1:
        raise ValidationError('invalidSize')
    name = 'ntfslite-check-' + (run_id or uuid.uuid4().hex)
    manifest = {'schema': 1, 'directory': name, 'files': {}, 'deleted': DELETED.copy(),
                'checks': 0, 'status': 'fileChecksPassed', 'windowsVerified': False}
    with Workspace(root, name, create=True) as workspace:
        def checked(filename, data, mode='create'):
            workspace.write(filename, [data], mode)
            expected = expectation(data)
            workspace.verify_file(filename, expected)
            manifest['files'][filename] = expected
            manifest['checks'] += 1
            progress(filename)

        checked('empty.bin', b'')
        for size in range(1, 17):
            checked(f'tiny-{size:02}.bin', bytes(range(1, size + 1)))
        checked('中文 空格 🧪.bin', '跨平台文件内容\n'.encode('utf8'))
        checked('overwrite.bin', BLOCK[:4096])
        checked('overwrite.bin', b'short', 'overwrite')
        checked('overwrite.bin', BLOCK[:8193], 'overwrite')
        checked('append.bin', b'head')
        appended = b'head'
        for tail in [b'x', BLOCK[:4097]]:
            workspace.write('append.bin', [tail], 'append')
            appended += tail
            workspace.verify_file('append.bin', expectation(appended))
            manifest['files']['append.bin'] = expectation(appended)
            manifest['checks'] += 1
        checked('before-rename.bin', b'rename-content')
        workspace.check()
        os.rename('before-rename.bin', 'renamed.bin', src_dir_fd=workspace.fd, dst_dir_fd=workspace.fd)
        manifest['files']['renamed.bin'] = manifest['files'].pop('before-rename.bin')
        workspace.absent('before-rename.bin')
        workspace.verify_file('renamed.bin', manifest['files']['renamed.bin'])
        manifest['checks'] += 1
        checked('replace-source.bin', b'replacement')
        workspace.check()
        os.replace('replace-source.bin', 'renamed.bin', src_dir_fd=workspace.fd, dst_dir_fd=workspace.fd)
        manifest['files']['renamed.bin'] = manifest['files'].pop('replace-source.bin')
        workspace.absent('replace-source.bin')
        workspace.verify_file('renamed.bin', manifest['files']['renamed.bin'])
        manifest['checks'] += 1
        checked('deleted.bin', b'delete-content')
        os.unlink('deleted.bin', dir_fd=workspace.fd)
        manifest['files'].pop('deleted.bin')
        workspace.absent('deleted.bin')
        os.mkdir('directory-before', 0o700, dir_fd=workspace.fd)
        os.rename('directory-before', 'directory-after', src_dir_fd=workspace.fd, dst_dir_fd=workspace.fd)
        workspace.absent('directory-before')
        if not stat.S_ISDIR(os.stat('directory-after', dir_fd=workspace.fd, follow_symlinks=False).st_mode):
            raise ValidationError('directoryRenameFailed')
        os.rmdir('directory-after', dir_fd=workspace.fd)
        workspace.absent('directory-after')
        os.mkdir('nonempty', 0o700, dir_fd=workspace.fd)
        child = os.open('nonempty', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=workspace.fd)
        try:
            fd = os.open('child', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=child)
            os.close(fd)
            try:
                os.rmdir('nonempty', dir_fd=workspace.fd)
            except OSError as error:
                if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                    raise
            else:
                raise ValidationError('nonemptyDirectoryRemoved')
            os.unlink('child', dir_fd=child)
        finally:
            os.close(child)
        os.rmdir('nonempty', dir_fd=workspace.fd)
        manifest['checks'] += 4
        if large_bytes:
            if os.fstatvfs(workspace.fd).f_bavail * os.fstatvfs(workspace.fd).f_frsize < large_bytes + 64 * 1024**2:
                raise ValidationError('insufficientSpace')
            digest = hashlib.sha256()
            def chunks():
                remaining = large_bytes
                while remaining:
                    chunk = BLOCK[:min(remaining, len(BLOCK))]
                    digest.update(chunk)
                    yield chunk
                    remaining -= len(chunk)
            workspace.write('large.bin', chunks())
            manifest['files']['large.bin'] = {'bytes': large_bytes, 'sha256': digest.hexdigest()}
            workspace.verify_file('large.bin', manifest['files']['large.bin'])
            manifest['checks'] += 1
            progress('large.bin')
    verify(root, manifest)
    return manifest


def validate_manifest(manifest):
    if (set(manifest) != {'schema', 'directory', 'files', 'deleted', 'checks', 'status', 'windowsVerified'}
            or manifest['schema'] != 1 or manifest['windowsVerified'] is not False
            or manifest['status'] != 'fileChecksPassed' or manifest['deleted'] != DELETED
            or not isinstance(manifest['files'], dict) or not manifest['files']
            or set(manifest['files']) not in (NAMES, NAMES - {'large.bin'})
            or type(manifest['schema']) is not int
            or type(manifest['checks']) is not int
            or manifest['checks'] != (34 if 'large.bin' in manifest['files'] else 33)):
        raise ValidationError('invalidManifest')
    for value in manifest['files'].values():
        if (set(value) != {'bytes', 'sha256'} or type(value['bytes']) is not int
                or not 0 <= value['bytes'] <= 4 * 1024**3 + 1
                or not isinstance(value['sha256'], str)
                or not re.fullmatch('[0-9a-f]{64}', value['sha256'])):
            raise ValidationError('invalidManifest')


def verify(root, manifest):
    validate_manifest(manifest)
    with Workspace(root, manifest['directory']) as workspace:
        if set(os.listdir(workspace.fd)) != set(manifest['files']):
            raise ValidationError('unexpectedEntries')
        for name, expected in manifest['files'].items():
            workspace.verify_file(name, expected)
        for name in manifest['deleted']:
            workspace.absent(name)


def cleanup(root, manifest):
    verify(root, manifest)
    with Workspace(root, manifest['directory']) as workspace:
        for name, expected in manifest['files'].items():
            workspace.verify_file(name, expected)
            os.unlink(name, dir_fd=workspace.fd)
            workspace.absent(name)
        workspace.check()
        os.rmdir(workspace.name, dir_fd=workspace.root_fd)
        try:
            os.stat(workspace.name, dir_fd=workspace.root_fd, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise ValidationError('cleanupIncomplete')
