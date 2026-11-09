"""lagwatch: a once-a-second record of what the machine was waiting on, so a
stutter can be looked up after the fact instead of guessed at.

  lagwatch record          the service (modules/features/lagwatch.nix)
  lagwatch mark [note]     "it lagged just now" -- bound to Mod+Ctrl+L
  lagwatch report [min]    each lag in the last [min] minutes (default 60)
                           with the seconds around it

Every second, as the share of that second (not PSI's 10s average, which
smears a half-second freeze into a 5% bump): how long tasks stalled on CPU,
memory and I/O; how busy the NVMe was and what it moved; swap (zram)
traffic; the NVMe's hottest sensor; and the cgroups that used the most CPU,
disk and swap, which is what names the culprit. `dt` is the real interval:
a second that took 1.8s is a stall the recorder itself sat through.

Lags come from your marks, from libinput's "your system is too slow" (niri
falling behind on input), from bus-lock bursts (a process doing split
atomics, which stall every core), and from corkboard's slow keys
(~/.local/state/corkboard/latency.jsonl).
"""

import glob
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

LOG_DIR = os.environ.get("LAGWATCH_DIR", "/var/log/lagwatch")
KEEP_DAYS = 3
ZRAM = "253:0"
CG = "/sys/fs/cgroup"


def psi_totals():
    out = {}
    for res in ("cpu", "memory", "io"):
        with open(f"/proc/pressure/{res}") as f:
            for line in f:
                kind, *fields = line.split()
                out[f"{res}_{kind}"] = int(fields[-1].split("=")[1])
    return out


def disk(dev="nvme0n1"):
    with open("/proc/diskstats") as f:
        for line in f:
            p = line.split()
            if p[2] == dev:
                return int(p[5]), int(p[9]), int(p[12])  # rsect, wsect, io_ms
    return 0, 0, 0


def nvme_temp():
    best = None
    for name in glob.glob("/sys/class/hwmon/hwmon*/name"):
        with open(name) as f:
            if f.read().strip() != "nvme":
                continue
        for t in glob.glob(os.path.dirname(name) + "/temp*_input"):
            with open(t) as f:
                v = int(f.read()) // 1000
            best = v if best is None else max(best, v)
    return best


def meminfo():
    m = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":")
            m[k] = int(v.split()[0]) // 1024
    return m


def leaves():
    """Leaf cgroups: where the processes are, so where blame goes."""
    out = []
    for d, subdirs, files in os.walk(CG):
        if "cpu.stat" in files and not any(
            os.path.exists(os.path.join(d, s, "cpu.stat")) for s in subdirs
        ):
            out.append(d)
    return out


def cg_counters(path):
    cpu = io = swap = 0
    try:
        with open(path + "/cpu.stat") as f:
            cpu = int(f.readline().split()[1])
        with open(path + "/io.stat") as f:
            for line in f:
                dev, *kv = line.split()
                n = sum(int(x.split("=")[1]) for x in kv if x[:6] in ("rbytes", "wbytes"))
                if dev == ZRAM:
                    swap += n
                else:
                    io = max(io, n)  # dm-0 and the NVMe under it count the same bytes
    except OSError:
        pass
    return cpu, io, swap


def short(path):
    name = path.rsplit("/", 1)[-1]
    return re.sub(r"\.(scope|service)$", "", name.replace("\\x2d", "-"))


def top(deltas, i, n=3, floor=0):
    ranked = sorted(deltas.items(), key=lambda kv: -kv[1][i])
    return [[short(k), round(v[i])] for k, v in ranked[:n] if v[i] > floor]


def record():
    os.makedirs(LOG_DIR, exist_ok=True)
    os.nice(-5)
    cgs, cgs_at = leaves(), time.monotonic()
    prev_t = time.monotonic()
    prev_psi, prev_disk = psi_totals(), disk()
    prev_cg = {c: cg_counters(c) for c in cgs}
    out, day = None, None
    while True:
        time.sleep(1 - (time.monotonic() - prev_t) % 1)
        now = time.monotonic()
        dt = now - prev_t
        if now - cgs_at > 30:
            cgs, cgs_at = leaves(), now
        psi, dsk = psi_totals(), disk()
        cg = {c: cg_counters(c) for c in cgs}
        us = dt * 1e6
        stall = {k: round(100 * (psi[k] - prev_psi[k]) / us, 1) for k in psi}
        deltas = {}
        for c, (cpu, io, swap) in cg.items():
            p = prev_cg.get(c)
            if p:
                deltas[c] = (
                    100 * (cpu - p[0]) / us,  # % of one core
                    (io - p[1]) / 1e6,  # MB
                    (swap - p[2]) / 1e6,
                )
        m = meminfo()
        row = {
            "t": round(time.time(), 3),
            "dt": round(dt, 3),
            "stall": stall,
            "disk": {
                "busy": round(100 * (dsk[2] - prev_disk[2]) / (dt * 1000)),
                "r_mb": round((dsk[0] - prev_disk[0]) * 512 / 1e6, 1),
                "w_mb": round((dsk[1] - prev_disk[1]) * 512 / 1e6, 1),
            },
            "temp": nvme_temp(),
            "avail_mb": m["MemAvailable"],
            "swap_mb": m["SwapTotal"] - m["SwapFree"],
            "cpu": top(deltas, 0, floor=5),
            "io": top(deltas, 1, floor=0.5),
            "swapio": top(deltas, 2, floor=0.5),
        }
        today = datetime.now().strftime("%Y-%m-%d")
        if today != day:
            if out:
                out.close()
            out, day = open(f"{LOG_DIR}/{today}.jsonl", "a", buffering=1), today
            for old in sorted(glob.glob(f"{LOG_DIR}/*.jsonl"))[:-KEEP_DAYS]:
                os.remove(old)
        out.write(json.dumps(row, separators=(",", ":")) + "\n")
        prev_t, prev_psi, prev_disk, prev_cg = now, psi, dsk, cg


def mark(note):
    subprocess.run(["logger", "-t", "lagwatch-mark", note or "lag"], check=False)
    subprocess.run(
        ["notify-send", "-t", "1500", "lagwatch", "marked: " + (note or "lag")],
        check=False,
    )


def journal(minutes, *args):
    r = subprocess.run(
        ["journalctl", "-b", "--since", f"-{minutes}min", "-o", "json", "--no-pager", *args],
        capture_output=True,
        text=True,
    )
    for line in r.stdout.splitlines():
        e = json.loads(line)
        msg = e.get("MESSAGE")
        if isinstance(msg, str):
            yield int(e["__REALTIME_TIMESTAMP"]) / 1e6, msg


def events(minutes):
    ev = []
    for t, msg in journal(minutes, "-t", "lagwatch-mark"):
        ev.append((t, "mark", msg))
    for t, msg in journal(minutes, "--user", "-g", "too slow"):
        lag = re.search(r"by (\d+)ms|\((-?\d+)ms\)", msg)
        ev.append((t, "niri", f"input {lag.group(1) or lag.group(2).lstrip('-')}ms behind" if lag else msg[:60]))
    locks = [t for t, _ in journal(minutes, "-k", "-g", "bus_lock trap")]
    i = 0
    while i < len(locks):  # bursts: 10+ within a second
        j = i
        while j + 1 < len(locks) and locks[j + 1] - locks[i] < 1:
            j += 1
        if j - i >= 9:
            ev.append((locks[i], "bus lock", f"{j - i + 1}+ split locks"))
        i = j + 1
    lat = os.path.expanduser("~/.local/state/corkboard/latency.jsonl")
    since = time.time() - minutes * 60
    if os.path.exists(lat):
        with open(lat) as f:
            for line in f:
                s = json.loads(line)
                t = s["t"] / 1000
                if t >= since and not s.get("busy") and (s.get("paint") or 0) > 100:
                    ev.append((t, "corkboard", f"{s['key']} took {round(s['paint'])}ms"))
    return sorted(ev)


def samples(start, end):
    rows = []
    for day in {datetime.fromtimestamp(start).strftime("%Y-%m-%d"), datetime.fromtimestamp(end).strftime("%Y-%m-%d")}:
        try:
            with open(f"{LOG_DIR}/{day}.jsonl") as f:
                for line in f:
                    r = json.loads(line)
                    if start <= r["t"] <= end:
                        rows.append(r)
        except FileNotFoundError:
            pass
    return sorted(rows, key=lambda r: r["t"])


def fmt(r, at):
    s, d = r["stall"], r["disk"]
    blame = lambda xs, unit: " ".join(f"{n}:{v}{unit}" for n, v in xs) or "-"
    return (
        f"  {r['t'] - at:+5.0f}s {'  ' if r['dt'] < 1.3 else 'dt' + str(r['dt'])}"
        f" cpu {s['cpu_some']:4.0f}  mem {s['memory_full']:4.0f}  io {s['io_full']:4.0f}"
        f" | nvme {d['busy']:3d}% r{d['r_mb']:5.1f} w{d['w_mb']:5.1f} {r['temp']}C"
        f" | swap {r['swap_mb']}M avail {r['avail_mb']}M"
        f" | cpu {blame(r['cpu'], '%')}  io {blame(r['io'], 'MB')}  swap {blame(r['swapio'], 'MB')}"
    )


def report(minutes):
    ev = events(minutes)
    if not ev:
        print(f"no lags in the last {minutes} min (marks, niri input stalls, bus-lock bursts, slow corkboard keys)")
    print("stall columns: % of that second all tasks waited (cpu some, mem full, io full)\n")
    shown_until = 0
    for t, kind, what in ev:
        when = datetime.fromtimestamp(t).strftime("%H:%M:%S")
        print(f"{when}  {kind}: {what}")
        if t - 5 < shown_until:
            continue  # overlaps the window just printed
        rows = samples(t - 5, t + 2)
        for r in rows:
            print(fmt(r, t))
        if not rows:
            print("  (no samples: lagwatch wasn't recording)")
        shown_until = t + 2
        print()
    # The worst seconds whether or not anyone noticed them.
    worst = sorted(samples(time.time() - minutes * 60, time.time()), key=lambda r: -max(r["stall"]["io_full"], r["stall"]["memory_full"], r["stall"]["cpu_some"]))[:5]
    if worst:
        print("worst seconds overall:")
        for r in worst:
            print(datetime.fromtimestamp(r["t"]).strftime("%H:%M:%S") + fmt(r, r["t"])[8:])


def main():
    cmd, *rest = sys.argv[1:] or ["report"]
    if cmd == "record":
        record()
    elif cmd == "mark":
        mark(" ".join(rest))
    elif cmd == "report":
        report(int(rest[0]) if rest else 60)
    else:
        sys.exit(__doc__)


main()
