#!/usr/bin/env python3
"""Exercise the real read-only CLI with stdin held open, without disk mutations."""

import hashlib
import os
from pathlib import Path
import re
import selectors
import subprocess
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / ".build/release/NTFSLiteGate1EvidenceTool"


def capture_arguments():
    return [str(TOOL), "capture", "G1-" + uuid.uuid4().hex.upper(),
            "0.0.0", "1", "0" * 64]


def wait_for(process, predicate, timeout=10):
    output = bytearray()
    with selectors.DefaultSelector() as selector:
        selector.register(process.stderr, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if selector.select(max(0, deadline - time.monotonic())):
                chunk = os.read(process.stderr.fileno(), 65536)
                if not chunk:
                    break
                output.extend(chunk)
                text = output.decode("utf-8", errors="replace")
                if predicate(text):
                    return text
    raise AssertionError("CLI did not respond while stdin remained open")


def check_interactive_capture():
    with tempfile.TemporaryFile() as artifact:
        process = subprocess.Popen(capture_arguments(), stdin=subprocess.PIPE,
                                   stdout=artifact, stderr=subprocess.PIPE)
        try:
            wait_for(process, lambda text: "applicationRestart 表示" in text)
            # No command is needed for observation to progress. This also
            # checks that a partial command cannot stall disk callbacks.
            process.stdin.write(b"sta")
            process.stdin.flush()
            time.sleep(3)
            process.stdin.write(b"tus\n")
            process.stdin.flush()
            status = wait_for(process, lambda text: "状态=recording" in text)
            count = re.search(r"观测=(\d+)", status)
            assert count and int(count[1]) > 0, \
                "observation must progress while a partial stdin line is pending"
            # Invalid encoding and an oversized line must each be discarded
            # once, without losing the following command in the same write.
            process.stdin.write(b"\xff\n" + b"x" * 16384 + b"\nstatus\r\n")
            process.stdin.flush()
            recovered = wait_for(process, lambda text: "状态=recording" in text)
            assert recovered.count("命令无效。") == 2
            process.stdin.write(b"seal\n")
            process.stdin.flush()
            assert process.wait(timeout=15) == 0, "explicit seal must finish"
            artifact.seek(0)
            data = artifact.read()
            result = subprocess.run(
                [str(TOOL), "verify", hashlib.sha256(data).hexdigest()],
                input=data, capture_output=True, timeout=10)
            assert result.returncode == 0 and not result.stdout
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdin.close()
            process.stderr.close()
    print("PASS: status and seal respond with stdin open; artifact verifies")
    print("PASS: idle/partial input preserves observation; malformed lines recover")


def check_unsealed_input_end():
    for data in [b"", b"status\n", b"status", b"x" * 16384]:
        result = subprocess.run(capture_arguments(), input=data,
                                capture_output=True, timeout=15)
        assert result.returncode == 65 and not result.stdout, \
            "EOF without seal must exit with no canonical output"
    with tempfile.TemporaryDirectory() as directory:
        descriptor = os.open(directory, os.O_RDONLY)
        try:
            result = subprocess.run(capture_arguments(), stdin=descriptor,
                                    capture_output=True, timeout=15)
        finally:
            os.close(descriptor)
        assert result.returncode == 74 and not result.stdout, \
            "stdin read failure must exit with no canonical output"
    print("PASS: EOF and stdin read failure never produce an unsealed artifact")


if __name__ == "__main__":
    check_interactive_capture()
    check_unsealed_input_end()
