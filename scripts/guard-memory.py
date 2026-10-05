#!/usr/bin/env python3
"""Stop only this command's process group if a child exceeds 2.5 GB footprint."""
import ctypes
import os
import signal
import subprocess
import sys
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16), ("values", ctypes.c_uint64 * 35)]


libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
proc = subprocess.Popen(sys.argv[1:], start_new_session=True)
peaks = {}
while proc.poll() is None:
    rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
    parents = {int(row.split()[0]): int(row.split()[1]) for row in rows.splitlines()}
    descendants = {proc.pid}
    while True:
        more = {pid for pid, parent in parents.items() if parent in descendants}
        if more <= descendants:
            break
        descendants |= more
    for pid in descendants:
        usage = Usage()
        if libproc.proc_pid_rusage(pid, 4, ctypes.byref(usage)) != 0:
            continue
        footprint = max(usage.values[7], usage.values[28])
        peaks[pid] = max(peaks.get(pid, 0), footprint)
        if footprint > 2_500_000_000:
            print(f"Memory guard: pid={pid} footprint={footprint} exceeds 2.5 GB", file=sys.stderr, flush=True)
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait()
            sys.exit(99)
    time.sleep(0.5)
print(f"Memory guard: largest process footprint={max(peaks.values(), default=0)} bytes", file=sys.stderr)
sys.exit(proc.returncode)
