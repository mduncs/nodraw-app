#!/usr/bin/env python3
"""Enforce macOS physical-footprint limits for a command and its children.

The caller holds the shared heavy-command gate. Sample ten seconds of the first
cold-wheel phase when a benchmark phase file is supplied.
"""

import ctypes
import json
import os
import signal
import struct
import subprocess
import sys
import time

LIMIT_BYTES = int(2.5 * 1024**3)
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]


def physical_footprint(pid):
    buffer = ctypes.create_string_buffer(512)
    if libproc.proc_pid_rusage(pid, 2, buffer) != 0:
        return None
    # rusage_info_v2: UUID followed by seven UInt64 fields, then physical footprint.
    return struct.unpack_from('Q', buffer, 72)[0]


def descendants(pid):
    listing = subprocess.check_output(['ps', '-axo', 'pid=,ppid='], text=True)
    parents = {int(parts[0]): int(parts[1]) for line in listing.splitlines()
               if len(parts := line.split()) == 2}
    owned = {pid}
    while True:
        found = {child for child, parent in parents.items() if parent in owned}
        if found.issubset(owned):
            return owned
        owned.update(found)


def main():
    if len(sys.argv) < 2:
        raise SystemExit('Usage: grid-benchmark-monitor.py <command...>')
    peak = {}
    phase_path = os.environ.get('NODRAW_GRID_BENCH_PHASE')
    if phase_path:
        state = {
            'memoryPressure': subprocess.check_output(['memory_pressure'], text=True),
            'swapUsage': subprocess.check_output(['sysctl', 'vm.swapusage'], text=True),
        }
        with open(os.path.join(os.path.dirname(phase_path), 'machine-state.json'), 'w') as output:
            json.dump(state, output, indent=2)
    process = subprocess.Popen(sys.argv[1:], start_new_session=True)
    sampler = None
    sampled = False
    exceeded = False
    try:
        while process.poll() is None:
            for pid in descendants(process.pid):
                size = physical_footprint(pid)
                if size is None:
                    continue
                peak[pid] = max(peak.get(pid, 0), size)
                if size > LIMIT_BYTES:
                    print(f'FOOTPRINT LIMIT EXCEEDED: pid={pid} bytes={size}', flush=True)
                    exceeded = True
                    os.killpg(process.pid, signal.SIGTERM)
                    break
            if exceeded:
                break
            if phase_path and not sampled and os.path.exists(phase_path):
                with open(phase_path) as phase:
                    marker = phase.read().split()
                if len(marker) == 2 and marker[1] == 'cold-wheel':
                    output = os.path.join(os.path.dirname(phase_path), 'cold-wheel.sample.txt')
                    sampler = subprocess.Popen(['sample', marker[0], '10', '-file', output],
                                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    sampled = True
            time.sleep(1)
        process.wait()
    finally:
        # A denied monitor operation must not leave an unmonitored build behind.
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait()
        if sampler:
            sampler.wait()
    summary = {'maximumPhysicalFootprintBytes': max(peak.values(), default=0),
               'peakBytesByPID': peak, 'limitBytes': LIMIT_BYTES}
    if phase_path:
        with open(os.path.join(os.path.dirname(phase_path), 'footprints.json'), 'w') as output:
            json.dump(summary, output, indent=2)
    print('GUARD maximum physical footprint bytes:', summary['maximumPhysicalFootprintBytes'], flush=True)
    return 1 if exceeded else process.returncode


if __name__ == '__main__':
    sys.exit(main())
