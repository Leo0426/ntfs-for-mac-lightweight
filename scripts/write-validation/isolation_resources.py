"""Shared isolated-experiment lease and child quiescence primitives (no disk commands)."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import uuid

from usb_target import require

LEASE_PATH = '/private/var/run/ntfslite-usb-lab.lock'
MAX_JOURNAL_BYTES = 65536
MAX_RECORDS = 256


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':')) + '\n').encode()


class IsolationLease:
    def __init__(self, path=LEASE_PATH, owner_uid=0):
        self.path, self.owner_uid, self.fd = path, owner_uid, None
        self.phase = "leaseOpen"
        self.records = []
        self.history_path = str(path) + ".journal-started"

    def __enter__(self):
        flags = os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_APPEND
        try:
            fd = os.open(self.path, flags | os.O_CREAT | os.O_EXCL, 0o600)
            self.created = True
        except FileExistsError:
            fd = os.open(self.path, flags)
            self.created = False
        try:
            self.phase = "leaseMetadata"
            info = os.fstat(fd)
            linked = os.lstat(self.path)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == self.owner_uid
                    and info.st_nlink == 1 and info.st_mode & 0o777 == 0o600
                    and (info.st_dev, info.st_ino) == (linked.st_dev, linked.st_ino), 'unsafeLeaseFile')
            self.phase = "leaseAcquire"
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.phase = "leaseJournal"
            self._validate_history(fd)
            before = os.fstat(fd)
            require(before.st_size <= MAX_JOURNAL_BYTES, 'leaseJournalTooLarge')
            data = os.pread(fd, MAX_JOURNAL_BYTES + 1, 0)
            after = os.fstat(fd)
            require(len(data) == before.st_size
                    and all(getattr(before, k) == getattr(after, k)
                            for k in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')),
                    'leaseJournalIncompleteRead')
            self.records = self._parse(data)
            require(not self.records or self.records[-1]['state'] == 'completed', 'priorMutationQuiescencePending')
            self.fd = fd
            return self
        except BaseException:
            os.close(fd)
            raise

    def _validate_history(self, fd):
        info = os.fstat(fd)
        if not os.path.lexists(self.history_path):
            require(info.st_size == 0, 'leaseHistoryMissing')
            require(self.created, 'existingEmptyLeaseUnverified')
            return
        marker = os.open(self.history_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            bound = os.fstat(marker)
            require(stat.S_ISREG(bound.st_mode) and bound.st_uid == self.owner_uid
                    and bound.st_nlink == 1 and bound.st_mode & 0o777 == 0o600, 'unsafeLeaseHistory')
            expected = canonical({'schema': 1, 'leaseDev': info.st_dev, 'leaseInode': info.st_ino})
            require(os.read(marker, 1024) == expected and info.st_size > 0, 'leaseHistoryCorruptOrCleared')
        finally:
            os.close(marker)

    @staticmethod
    def _parse(data):
        require(type(data) is bytes and len(data) <= MAX_JOURNAL_BYTES, 'leaseJournalTooLarge')
        if not data:
            return []
        require(data.endswith(b'\n'), 'leaseJournalTruncated')
        lines = data.splitlines(keepends=True)
        require(len(lines) <= MAX_RECORDS, 'leaseJournalTooManyRecords')
        records = []
        keys = {'schema', 'sequence', 'operation', 'kind', 'state', 'ownerPID', 'childPID'}
        for line in lines:
            try:
                value = json.loads(line)
            except (ValueError, UnicodeError):
                require(False, 'leaseJournalMalformed')
            require(type(value) is dict and set(value) == keys and canonical(value) == line,
                    'leaseJournalNonCanonical')
            require(type(value['schema']) is int and value['schema'] == 1
                    and type(value['sequence']) is int and value['sequence'] == len(records) + 1
                    and type(value['ownerPID']) is int and 0 < value['ownerPID'] <= 2147483647
                    and isinstance(value['operation'], str) and len(value['operation']) == 32
                    and all(c in '0123456789abcdef' for c in value['operation'])
                    and value['kind'] in ('prepareMutation', 'usbExperiment')
                    and value['state'] in ('pending', 'child', 'completed')
                    and (value['childPID'] is None or type(value['childPID']) is int and 0 < value['childPID'] <= 2147483647),
                    'leaseJournalUnknownFacts')
            previous = records[-1] if records else None
            if value['state'] == 'pending':
                require(value['childPID'] is None and (previous is None or previous['state'] == 'completed')
                        and not any(r['operation'] == value['operation'] for r in records), 'leaseJournalInvalidTransition')
            else:
                require(previous is not None and previous['state'] in ('pending', 'child')
                        and all(previous[k] == value[k] for k in ('operation', 'kind', 'ownerPID')),
                        'leaseJournalInvalidTransition')
                if value['state'] == 'child':
                    require(value['childPID'] is not None, 'leaseJournalChildMissing')
                else:
                    require(value['childPID'] == previous['childPID']
                            and (value['kind'] != 'prepareMutation' or previous['state'] == 'child'),
                            'leaseJournalChildMissing')
            records.append(value)
        return records

    def _append(self, value):
        require(self.fd is not None, 'leaseOwnershipRequired')
        prior = b''.join(canonical(item) for item in self.records)
        info, linked = os.fstat(self.fd), os.lstat(self.path)
        require(info.st_size == len(prior) and info.st_nlink == 1
                and (info.st_dev, info.st_ino) == (linked.st_dev, linked.st_ino), 'leaseJournalChangedWhileOwned')
        require(os.pread(self.fd, MAX_JOURNAL_BYTES + 1, 0) == prior, 'leaseJournalChangedWhileOwned')
        self._parse(prior + canonical(value))
        # Never truncate, overwrite, rotate or silently discard an earlier pending record.
        data = canonical(value)
        require(os.write(self.fd, data) == len(data), 'leaseJournalWriteIncomplete')
        os.fsync(self.fd)
        self.records.append(value)

    def begin(self, kind):
        require(self.fd is not None and kind in ('prepareMutation', 'usbExperiment')
                and (not self.records or self.records[-1]['state'] == 'completed'), 'leaseMutationAlreadyPending')
        require(len(self.records) <= MAX_RECORDS - 16
                and sum(len(canonical(item)) for item in self.records) <= MAX_JOURNAL_BYTES - 4096,
                'leaseJournalCapacityBlocked')
        if not self.records:
            info = os.fstat(self.fd)
            marker = os.open(self.history_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                data = canonical({'schema': 1, 'leaseDev': info.st_dev, 'leaseInode': info.st_ino})
                require(os.write(marker, data) == len(data), 'leaseHistoryWriteIncomplete')
                os.fsync(marker)
                directory = os.open(str(Path(self.history_path).parent), os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                os.close(marker)
        self._append({'schema': 1, 'sequence': len(self.records) + 1, 'operation': uuid.uuid4().hex,
                      'kind': kind, 'state': 'pending', 'ownerPID': os.getpid(), 'childPID': None})

    def record_child(self, pid):
        require(self.records and self.records[-1]['state'] in ('pending', 'child'), 'leaseMutationNotPending')
        self._append({**self.records[-1], 'sequence': len(self.records) + 1, 'state': 'child', 'childPID': pid})

    def complete(self, verify):
        require(self.records and self.records[-1]['state'] in ('pending', 'child'), 'leaseMutationNotPending')
        verify()  # Caller must independently prove child reaping AND fresh system quiescence.
        self._append({**self.records[-1], 'sequence': len(self.records) + 1, 'state': 'completed'})

    def __exit__(self, *_):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


@contextmanager
def retain_interrupts(report):
    """Capture requests without unwinding resource ownership or signaling the child."""
    state = {'interrupted': False}
    def retain(signum, _frame):
        state['interrupted'] = True
        report('quiescencePending', reason='interrupt', signal=signum,
               instruction='保持终端开启；继续持有租约，等待子进程及新的系统事实。')
    previous = {item: signal.getsignal(item) for item in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        for item in previous:
            signal.signal(item, retain)
        yield state
    finally:
        for item, handler in previous.items():
            signal.signal(item, handler)


def wait_for_mutation(process, timeout=30, pending=None):
    """Never terminate a mutation. Propagate cancellation only after child reaping."""
    interrupted = False
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        pass
    except (KeyboardInterrupt, InterruptedError):
        interrupted = True
    if pending:
        pending()
    while True:
        try:
            result = process.wait()
            break
        except (KeyboardInterrupt, InterruptedError):
            interrupted = True
            if pending:
                pending()
    if interrupted:
        raise InterruptedError('mutationInterruptedAfterChildReaped')
    return result
