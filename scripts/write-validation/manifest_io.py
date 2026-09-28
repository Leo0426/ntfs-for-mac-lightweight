"""Persist file-check expectations; neither a volume identity nor mount evidence."""
import hashlib
import json
import os
import stat
from pathlib import Path
from contextlib import contextmanager

from file_cycle import ValidationError, identity, validate_manifest

MAX_DOCUMENT_BYTES = 16384


def file_stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def regular_file(info):
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or not 0 < info.st_size <= MAX_DOCUMENT_BYTES):
        raise ValidationError('unsafeManifestFile')


@contextmanager
def parent_directory(path):
    path = Path(path).absolute()
    if path.parent.resolve(strict=True) != path.parent or path.name in ('', '.', '..'):
        raise ValidationError('unsafeManifestPath')
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        def check():
            if (path.parent.resolve(strict=True) != path.parent
                    or identity(os.stat(path.parent, follow_symlinks=False)) != identity(os.fstat(fd))):
                raise ValidationError('manifestDirectoryReplaced')
        check()
        yield fd, path.name, check
        check()
    finally:
        os.close(fd)


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'),
                       ensure_ascii=True, allow_nan=False) + '\n').encode('ascii')


def save_manifest(path, manifest):
    validate_manifest(manifest)
    document = {'schema': 1, 'manifest': manifest,
                'sha256': hashlib.sha256(canonical(manifest)).hexdigest()}
    raw = canonical(document)
    if len(raw) > MAX_DOCUMENT_BYTES:
        raise ValidationError('manifestTooLarge')
    with parent_directory(path) as (parent, name, check):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=parent)
        try:
            remaining = memoryview(raw)
            while remaining:
                written = os.write(fd, remaining)
                if written <= 0:
                    raise ValidationError('shortManifestWrite')
                remaining = remaining[written:]
            os.fsync(fd)
            check()
            after = os.fstat(fd)
            regular_file(after)
            if file_stamp(os.stat(name, dir_fd=parent, follow_symlinks=False)) != file_stamp(after):
                raise ValidationError('manifestReplaced')
            os.fsync(parent)
        finally:
            os.close(fd)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValidationError('duplicateManifestKey')
        result[key] = value
    return result


def load_manifest(path):
    with parent_directory(path) as (parent, name, check):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            before = os.fstat(fd)
            regular_file(before)
            raw = bytearray()
            while chunk := os.read(fd, min(4096, MAX_DOCUMENT_BYTES + 1 - len(raw))):
                raw.extend(chunk)
                if len(raw) > MAX_DOCUMENT_BYTES:
                    raise ValidationError('manifestTooLarge')
            after = os.fstat(fd)
            named = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if (file_stamp(before) != file_stamp(after) or file_stamp(named) != file_stamp(after)
                    or len(raw) != before.st_size):
                raise ValidationError('manifestChangedDuringRead')
            check()
        finally:
            os.close(fd)
    try:
        document = json.loads(raw.decode('ascii'), object_pairs_hook=unique_object)
        if (not isinstance(document, dict) or set(document) != {'schema', 'manifest', 'sha256'}
                or type(document['schema']) is not int or document['schema'] != 1
                or raw != canonical(document)
                or document['sha256'] != hashlib.sha256(canonical(document['manifest'])).hexdigest()):
            raise ValidationError('invalidManifestDocument')
    except (ValueError, RecursionError) as error:
        raise ValidationError('invalidManifestDocument') from error
    validate_manifest(document['manifest'])
    return document['manifest']
