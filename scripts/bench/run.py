#!/usr/bin/env python3
"""The measuring half of scripts/bench.sh (which builds, generates the data
and starts the scratch server, then runs this with its PID and port).

Load: oha or hey when installed (and --tool asks or is auto), else a small
built-in generator: C worker processes, each one keep-alive connection,
looping over the endpoint for D seconds. Every request carries
`X-Pocketpi: 1` and a 127.0.0.1 Host, as `guard` (src/main.rs) wants.

Resources come from /proc/<pid> (VmRSS, VmHWM, Threads, open fds), sampled
every 250 ms and summarised per phase. Standard library only.
"""
import argparse
import base64
import datetime
import http.client
import json
import multiprocessing as mp
import os
import shutil
import socket
import statistics
import subprocess
import sys
import threading
import time
import urllib.parse

HEADERS = {"X-Pocketpi": "1"}


# ------------------------------------------------------------------ /proc

def proc_stats(pid):
    s = {}
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                k, _, v = line.partition(":")
                if k in ("VmRSS", "VmHWM", "RssAnon", "RssFile"):
                    s[k.lower() + "_kb"] = int(v.split()[0])
                elif k == "Threads":
                    s["threads"] = int(v)
        s["fds"] = len(os.listdir(f"/proc/{pid}/fd"))
    except (FileNotFoundError, ProcessLookupError):
        return None
    return s


def children(pid):
    """Direct children's PIDs (the fake pis and terminal shells), from every
    thread: a child belongs to the thread that forked it."""
    out = []
    try:
        tasks = os.listdir(f"/proc/{pid}/task")
    except OSError:
        return out
    for t in tasks:
        try:
            with open(f"/proc/{pid}/task/{t}/children") as f:
                out.extend(int(p) for p in f.read().split())
        except OSError:
            pass
    return out


class Sampler(threading.Thread):
    def __init__(self, pid, every=0.25):
        super().__init__(daemon=True)
        self.pid, self.every = pid, every
        self.phase = "idle"
        self.samples = []  # (t, phase, stats)
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            s = proc_stats(self.pid)
            if s:
                self.samples.append((time.time(), self.phase, s))
            self.stop.wait(self.every)

    def peak(self, phase):
        ss = [s for _, p, s in self.samples if p == phase]
        if not ss:
            return {}
        return {"peak_rss_kb": max(s["vmrss_kb"] for s in ss), "peak_anon_kb": max(s["rssanon_kb"] for s in ss), "peak_threads": max(s["threads"] for s in ss),
                "peak_fds": max(s["fds"] for s in ss)}


def snap(pid):
    s = proc_stats(pid) or {}
    return {"rss_kb": s.get("vmrss_kb"), "hwm_kb": s.get("vmhwm_kb"), "anon_kb": s.get("rssanon_kb"), "file_kb": s.get("rssfile_kb"), "threads": s.get("threads"), "fds": s.get("fds")}


# ------------------------------------------------------------------ HTTP

def request(port, method, path, body=None, timeout=60):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    h = dict(HEADERS)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    out = r.read()
    c.close()
    if r.status >= 400:
        raise RuntimeError(f"{method} {path}: {r.status} {out[:200]!r}")
    return json.loads(out) if out else None


def timed_get(port, path):
    t = time.perf_counter()
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=120)
    c.request("GET", path, headers=HEADERS)
    r = c.getresponse()
    body = r.read()
    c.close()
    return (time.perf_counter() - t) * 1000, r.status, len(body)


def worker(args):
    """One connection looping over `paths` from start_at for `duration` s."""
    port, paths, start_at, duration = args
    lat, errors, nbytes = [], 0, 0
    conn = None
    i = 0
    while time.time() < start_at:
        time.sleep(0.001)
    end = start_at + duration
    while True:
        now = time.time()
        if now >= end:
            break
        path = paths[i % len(paths)]
        i += 1
        t = time.perf_counter()
        try:
            if conn is None:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
            conn.request("GET", path, headers=HEADERS)
            r = conn.getresponse()
            body = r.read()
            nbytes += len(body)
            if r.status >= 400:
                errors += 1
            else:
                lat.append((time.perf_counter() - t) * 1000)
        except Exception:
            errors += 1
            if conn is not None:
                conn.close()
            conn = None
    if conn is not None:
        conn.close()
    return lat, errors, nbytes


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    k = min(len(sorted_vals) - 1, max(0, int(round(p / 100 * len(sorted_vals) + 0.5)) - 1))
    return sorted_vals[k]


def summarise(lat, errors, nbytes, duration):
    lat.sort()
    n = len(lat)
    return {"requests": n + errors, "errors": errors, "rps": round(n / duration, 1),
            "p50_ms": r3(pct(lat, 50)), "p90_ms": r3(pct(lat, 90)), "p99_ms": r3(pct(lat, 99)),
            "max_ms": r3(lat[-1] if lat else None), "bytes_per_req": int(nbytes / max(1, n + errors))}


def r3(x):
    return None if x is None else round(x, 3)


def load_python(pool, port, paths, duration, conc):
    start_at = time.time() + 0.3
    res = pool.map(worker, [(port, paths, start_at, duration)] * conc)
    lat = [x for r in res for x in r[0]]
    return summarise(lat, sum(r[1] for r in res), sum(r[2] for r in res), duration)


def load_oha(port, path, duration, conc):
    out = subprocess.run(["oha", "-z", f"{duration}s", "-c", str(conc), "--no-tui", "--json", "-H", "X-Pocketpi: 1",
                          f"http://127.0.0.1:{port}{path}"], capture_output=True, text=True, check=True).stdout
    j = json.loads(out)
    s, lp = j["summary"], j.get("latencyPercentiles", {})
    codes = j.get("statusCodeDistribution", {})
    ok = sum(v for k, v in codes.items() if int(k) < 400)
    bad = sum(v for k, v in codes.items() if int(k) >= 400) + sum(j.get("errorDistribution", {}).values())
    ms = lambda x: r3(x * 1000) if x is not None else None
    return {"requests": ok + bad, "errors": bad, "rps": round(s.get("requestsPerSec", 0), 1),
            "p50_ms": ms(lp.get("p50")), "p90_ms": ms(lp.get("p90")), "p99_ms": ms(lp.get("p99")),
            "max_ms": ms(s.get("slowest")), "bytes_per_req": int(s.get("sizePerRequest") or 0)}


def load_hey(port, path, duration, conc):
    import re
    out = subprocess.run(["hey", "-z", f"{duration}s", "-c", str(conc), "-H", "X-Pocketpi: 1",
                          f"http://127.0.0.1:{port}{path}"], capture_output=True, text=True, check=True).stdout
    num = lambda pat: float(m.group(1)) if (m := re.search(pat, out)) else None
    codes = {int(c): int(n) for c, n in re.findall(r"\[(\d{3})\]\s+(\d+) responses", out)}
    errs = sum(n for c, n in codes.items() if c >= 400) + sum(int(n) for n in re.findall(r"\[(\d+)\]\s+Get ", out))
    ms = lambda x: r3(x * 1000) if x is not None else None
    return {"requests": sum(codes.values()) + errs, "errors": errs, "rps": num(r"Requests/sec:\s+([\d.]+)"),
            "p50_ms": ms(num(r"50%+ in ([\d.]+) secs")), "p90_ms": ms(num(r"90%+ in ([\d.]+) secs")),
            "p99_ms": ms(num(r"99%+ in ([\d.]+) secs")), "max_ms": ms(num(r"Slowest:\s+([\d.]+) secs")),
            "bytes_per_req": int(num(r"Size/request:\s+([\d.]+) bytes") or 0)}


# ------------------------------------------------------------------ SSE

class SseClient(threading.Thread):
    """Reads one chat's event stream; records (arrival time, type) per event."""

    def __init__(self, port, key):
        super().__init__(daemon=True)
        self.port, self.key = port, key
        self.events = []
        self.hello = threading.Event()
        self.error = None
        self.done = threading.Event()
        self.sock = None

    def run(self):
        try:
            c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=120)
            c.request("GET", f"/api/s/{self.key}/events", headers={**HEADERS, "Accept": "text/event-stream"})
            r = c.getresponse()
            if r.status != 200:
                raise RuntimeError(f"events: {r.status}")
            self.sock = c.sock
            while True:
                line = r.readline()
                if not line:
                    break
                if not line.startswith(b"data:"):
                    continue
                now = time.perf_counter()
                try:
                    ty = json.loads(line[5:]).get("type")
                except ValueError:
                    ty = "?"
                self.events.append((now, ty))
                if ty == "pocketpi_hello":
                    self.hello.set()
                if ty in ("agent_settled", "pocketpi_turn_files"):
                    self.done.set()
        except Exception as e:  # closed on purpose at the end, or a real error
            if not self.done.is_set():
                self.error = repr(e)
        finally:
            self.hello.set()
            self.done.set()

    def close(self):
        try:
            if self.sock:
                self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def sse_fanout(port, cwd, n_clients, words, sampler):
    key = request(port, "POST", "/api/new", {"cwd": cwd})["key"]
    clients = [SseClient(port, key) for _ in range(n_clients)]
    for c in clients:
        c.start()
    for c in clients:
        c.hello.wait(30)
    connected = sum(1 for c in clients if c.events)
    sampler.phase = "sse"
    prompt = "bench " + " ".join(f"w{i}" for i in range(words))
    t0 = time.perf_counter()
    request(port, "POST", f"/api/s/{key}/cmd", {"type": "prompt", "message": prompt})
    for c in clients:
        c.done.wait(120)
    wall = time.perf_counter() - t0
    sampler.phase = "sse-after"
    # Events after the hello: the same sequence for every client; the
    # spread is how much later a client got an event than the fastest one.
    seqs = [[e for e in c.events if e[1] != "pocketpi_hello"] for c in clients]
    counts = [len(s) for s in seqs]
    n = min(counts) if counts else 0
    spreads = []
    for i in range(n):
        ts = [s[i][0] for s in seqs]
        first = min(ts)
        spreads.extend((t - first) * 1000 for t in ts)
    spreads.sort()
    end_lat = []
    for s in seqs:
        ends = [t for t, ty in s if ty == "agent_settled"]
        if ends:
            end_lat.append((ends[0] - t0) * 1000)
    resyncs = sum(1 for s in seqs for _, ty in s if ty == "pocketpi_resync")
    for c in clients:
        c.close()
    try:
        request(port, "POST", f"/api/s/{key}/close", {})
    except Exception:
        pass
    return {"clients": n_clients, "connected": connected, "events_per_client_min": min(counts) if counts else 0,
            "events_per_client_max": max(counts) if counts else 0, "resyncs": resyncs,
            "errors": sum(1 for c in clients if c.error), "turn_wall_ms": round(wall * 1000, 1),
            "settled_p50_ms": r3(statistics.median(end_lat)) if end_lat else None,
            "settled_max_ms": r3(max(end_lat)) if end_lat else None,
            "fanout_spread_p50_ms": r3(pct(spreads, 50)), "fanout_spread_p99_ms": r3(pct(spreads, 99)),
            "fanout_spread_max_ms": r3(spreads[-1] if spreads else None), **sampler.peak("sse")}


# ------------------------------------------------------------------ git snapshot per turn

def snapshot_turns(port, repo, turns, sampler):
    """A chat in the big repo; each prompt makes fake-pi write a file, so the
    server snapshots the work tree at agent_start and after agent_settled and
    sends pocketpi_turn_files. Measures settled -> turn_files (the after
    snapshot plus the diff) and prompt -> turn_files."""
    key = request(port, "POST", "/api/new", {"cwd": repo})["key"]
    sampler.phase = "snapshot"
    out = []
    for n in range(turns):
        c = SseClient(port, key)
        c.start()
        c.hello.wait(30)
        t0 = time.perf_counter()
        request(port, "POST", f"/api/s/{key}/cmd", {"type": "prompt", "message": f"write file bench turn {n}"})
        deadline = time.time() + 180
        files_t = settled_t = None
        while time.time() < deadline:
            for t, ty in list(c.events):
                if ty == "agent_settled" and settled_t is None:
                    settled_t = t
                if ty == "pocketpi_turn_files":
                    files_t = t
            if files_t:
                break
            time.sleep(0.01)
        c.done.set()
        c.close()
        if files_t is None or settled_t is None:
            out.append({"turn": n + 1, "error": "no pocketpi_turn_files within 180 s"})
            continue
        out.append({"turn": n + 1, "settled_to_files_ms": round((files_t - settled_t) * 1000, 1),
                    "prompt_to_files_ms": round((files_t - t0) * 1000, 1)})
    changes = request(port, "GET", f"/api/files/changes?key={key}")
    try:
        request(port, "POST", f"/api/s/{key}/close", {})
    except Exception:
        pass
    sampler.phase = "snapshot-after"
    ok = [t["settled_to_files_ms"] for t in out if "settled_to_files_ms" in t]
    return {"turns": out, "recorded_turns": len(changes.get("turns", [])), "git": changes.get("git"),
            "files_changed_last": len(changes["turns"][-1]["files"]) if changes.get("turns") else None,
            "settled_to_files_median_ms": r3(statistics.median(ok)) if ok else None,
            "settled_to_files_max_ms": r3(max(ok)) if ok else None, **sampler.peak("snapshot")}


# ------------------------------------------------------------------ terminals

def ws_open(port, root):
    s = socket.create_connection(("127.0.0.1", port), timeout=15)
    key = base64.b64encode(os.urandom(16)).decode()
    q = urllib.parse.urlencode({"root": root, "cols": 80, "rows": 24})
    s.sendall((f"GET /api/term/ws?{q} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nOrigin: http://127.0.0.1:{port}\r\n"
               f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
               "Sec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = s.recv(4096)
        if not chunk:
            break
        head += chunk
    if b" 101 " not in head.split(b"\r\n")[0]:
        s.close()
        raise RuntimeError(f"term ws: {head[:120]!r}")
    return s


def ws_send_text(s, text):
    data = text.encode()
    mask = os.urandom(4)
    hdr = bytes([0x81])
    n = len(data)
    hdr += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + n.to_bytes(2, "big")
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def drain(socks, secs):
    end = time.time() + secs
    for s in socks:
        s.setblocking(False)
    while time.time() < end:
        for s in socks:
            try:
                s.recv(65536)
            except (BlockingIOError, OSError):
                pass
        time.sleep(0.05)


def tree_rss_kb(pids):
    total = 0
    for p in pids:
        st = proc_stats(p)
        if st:
            total += st.get("vmrss_kb", 0)
    return total


def terminals(port, pid, root, n, sampler):
    sampler.phase = "terms"
    kids_before = set(children(pid))
    before = snap(pid)
    socks = [ws_open(port, root) for _ in range(n)]
    drain(socks, 1.5)
    after = snap(pid)
    shells = [p for p in children(pid) if p not in kids_before]
    shell_rss = tree_rss_kb(shells)
    for s in socks:
        s.setblocking(True)
        try:
            ws_send_text(s, json.dumps({"type": "close"}))
        except OSError:
            pass
    drain(socks, 0.5)
    for s in socks:
        s.close()
    time.sleep(0.5)
    closed = snap(pid)
    sampler.phase = "terms-after"
    d = lambda k: round((after[k] - before[k]) / n, 1)
    return {"terminals": n, "server_rss_per_term_kb": d("rss_kb"), "threads_per_term": d("threads"),
            "fds_per_term": d("fds"), "shell_rss_per_term_kb": round(shell_rss / max(1, len(shells)), 1),
            "server_rss_after_close_kb": closed["rss_kb"], "fds_after_close": closed["fds"],
            "threads_after_close": closed["threads"]}


# ------------------------------------------------------------------ soak

def soak(pool, port, pid, paths, secs, conc, sampler):
    idle_before = snap(pid)
    sampler.phase = "soak"
    t0 = time.time()
    # In 5 s slices, so each slice's errors and rps are visible.
    lat, errors, nbytes = [], 0, 0
    while time.time() - t0 < secs:
        sl = min(5, secs - (time.time() - t0))
        if sl < 1:
            break
        start_at = time.time() + 0.1
        res = pool.map(worker, [(port, paths, start_at, sl)] * conc)
        for r in res:
            lat.extend(r[0])
            errors += r[1]
            nbytes += r[2]
    dur = time.time() - t0
    sampler.phase = "soak-after"
    ss = [(t, s) for t, p, s in sampler.samples if p == "soak"]
    out = summarise(lat, errors, nbytes, dur)
    if len(ss) >= 8:
        third = len(ss) // 3
        first = statistics.median(s["vmrss_kb"] for _, s in ss[:third])
        last = statistics.median(s["vmrss_kb"] for _, s in ss[-third:])
        ts = [t - ss[0][0] for t, _ in ss]
        ys = [s["vmrss_kb"] for _, s in ss]
        mt, my = statistics.mean(ts), statistics.mean(ys)
        slope = sum((t - mt) * (y - my) for t, y in zip(ts, ys)) / max(1e-9, sum((t - mt) ** 2 for t in ts))
        fd_first = statistics.median(s["fds"] for _, s in ss[:third])
        fd_last = statistics.median(s["fds"] for _, s in ss[-third:])
        th_first = statistics.median(s["threads"] for _, s in ss[:third])
        th_last = statistics.median(s["threads"] for _, s in ss[-third:])
        anon_first = statistics.median(s["rssanon_kb"] for _, s in ss[:third])
        anon_last = statistics.median(s["rssanon_kb"] for _, s in ss[-third:])
        growth = (last - first) / first * 100
        rss_grows = growth > 5 and slope * 60 > 512
        # fds under load swing with the requests in flight; a leak shows idle.
        time.sleep(2)
        idle_after = snap(pid)
        fds_grow = idle_after["fds"] - idle_before["fds"] > 4
        out.update({"seconds": round(dur, 1), "rss_first_third_kb": int(first), "rss_last_third_kb": int(last),
                    "rss_growth_pct": round(growth, 1), "anon_first_third_kb": int(anon_first), "anon_last_third_kb": int(anon_last), "rss_slope_kb_per_min": round(slope * 60, 1),
                    "fds_first_third": fd_first, "fds_last_third": fd_last,
                    "idle_fds_before": idle_before["fds"], "idle_fds_after": idle_after["fds"],
                    "threads_first_third": th_first, "threads_last_third": th_last,
                    "verdict": ("GROWING: " + ", ".join(x for x, y in (("RSS", rss_grows), ("fds", fds_grow)) if y))
                    if (rss_grows or fds_grow) else "stable", **sampler.peak("soak")})
    else:
        out.update({"seconds": round(dur, 1), "verdict": "too short to tell"})
    return out


# ------------------------------------------------------------------ report

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True).stdout.strip()


def fmt(v, w=9):
    if v is None:
        return "-".rjust(w)
    if isinstance(v, float):
        return (f"{v:.1f}" if abs(v) >= 100 else f"{v:.2f}").rjust(w)
    return str(v).rjust(w)


def print_table(res):
    print()
    print(f"pocketpi bench  {res['date']}  {res['git_sha']}{' (dirty)' if res['git_dirty'] else ''}  "
          f"tool={res['config']['tool']}  sessions={res['config']['sessions']}  repo_files={res['config']['repo_files']}  "
          f"c={res['config']['concurrency']}  {res['config']['duration']}s/endpoint")
    print(f"binary {res['binary_bytes'] / 1e6:.1f} MB · ready in {res['startup']['ready_ms']} ms · "
          f"idle RSS {res['process']['start']['rss_kb'] / 1024:.1f} MB · load avg {res['loadavg_start'][0]} on {res['cpus']} CPUs "
          "(a busy machine makes the numbers noisy)")
    print()
    hdr = ["endpoint", "rps", "p50 ms", "p90 ms", "p99 ms", "max ms", "errors", "cold ms", "KB/req", "peakRSS MB", "thr", "fds"]
    print(f"{hdr[0]:<14}" + "".join(h.rjust(10) for h in hdr[1:]))
    for name, e in res["endpoints"].items():
        print(f"{name:<14}" + fmt(e["rps"], 10) + fmt(e["p50_ms"], 10) + fmt(e["p90_ms"], 10) + fmt(e["p99_ms"], 10)
              + fmt(e["max_ms"], 10) + fmt(e["errors"], 10) + fmt(e.get("cold_ms"), 10)
              + fmt(round(e["bytes_per_req"] / 1024, 1), 10) + fmt(round(e.get("peak_rss_kb", 0) / 1024, 1), 10)
              + fmt(e.get("peak_threads"), 10) + fmt(e.get("peak_fds"), 10))
    s = res.get("sse")
    if s:
        print(f"\nSSE fan-out: {s['connected']}/{s['clients']} clients, {s['events_per_client_min']}-{s['events_per_client_max']} events each, "
              f"turn {s['turn_wall_ms']:.0f} ms, spread p50 {s['fanout_spread_p50_ms']} / p99 {s['fanout_spread_p99_ms']} / "
              f"max {s['fanout_spread_max_ms']} ms, resyncs {s['resyncs']}, errors {s['errors']}, peak RSS {s.get('peak_rss_kb', 0) / 1024:.1f} MB")
    g = res.get("snapshot")
    if g:
        per = ", ".join(str(t.get("settled_to_files_ms", t.get("error"))) for t in g["turns"])
        print(f"Git snapshot per turn ({res['config']['repo_files']} files): settled->files median {g['settled_to_files_median_ms']} ms "
              f"(turns: {per}), recorded {g['recorded_turns']} turns, git={g['git']}")
    t = res.get("terminals")
    if t:
        if "error" in t:
            print(f"Terminals: {t['error']}")
        else:
            print(f"Terminals ({t['terminals']}): server +{t['server_rss_per_term_kb']} KB RSS, +{t['threads_per_term']} threads, "
                  f"+{t['fds_per_term']} fds per terminal; shell {t['shell_rss_per_term_kb']} KB each; "
                  f"after close: {t['fds_after_close']} fds, {t['threads_after_close']} threads")
    k = res.get("soak")
    if k:
        print(f"Soak {k.get('seconds')} s: {k['requests']} requests, {k['errors']} errors, {k['rps']} rps, p99 {k['p99_ms']} ms; "
              f"RSS {k.get('rss_first_third_kb', 0) / 1024:.1f} -> {k.get('rss_last_third_kb', 0) / 1024:.1f} MB "
              f"({k.get('rss_growth_pct')}%, {k.get('rss_slope_kb_per_min')} KB/min), anon {k.get('anon_first_third_kb', 0) / 1024:.1f} -> "
              f"{k.get('anon_last_third_kb', 0) / 1024:.1f} MB, idle fds {k.get('idle_fds_before')} -> {k.get('idle_fds_after')}: {k['verdict']}")
    p = res["process"]
    print("\nprocess      " + "".join(h.rjust(10) for h in ("RSS MB", "HWM MB", "anon MB", "file MB", "threads", "fds")))
    for ph in ("start", "after_load", "after_soak", "end"):
        if ph in p:
            q = p[ph]
            print(f"{ph:<13}" + fmt(round(q['rss_kb'] / 1024, 1), 10) + fmt(round(q['hwm_kb'] / 1024, 1), 10)
                  + fmt(round(q['anon_kb'] / 1024, 1), 10) + fmt(round(q['file_kb'] / 1024, 1), 10)
                  + fmt(q["threads"], 10) + fmt(q["fds"], 10))


def compare(res, out_dir, this_file):
    """Delta against the newest earlier result with the same config."""
    keys = ("sessions", "repo_files", "concurrency", "duration", "tool")
    prev = None
    for name in sorted(os.listdir(out_dir), reverse=True):
        path = os.path.join(out_dir, name)
        if not name.endswith(".json") or path == this_file:
            continue
        try:
            j = json.load(open(path))
        except ValueError:
            continue
        if all(j.get("config", {}).get(k) == res["config"][k] for k in keys) and j.get("date", "") < res["date"]:
            if prev is None or j["date"] > prev[1]["date"]:
                prev = (name, j)
    if not prev:
        print("\n(no earlier result with the same settings to compare with)")
        return []
    name, old = prev
    print(f"\nvs {name} ({old['git_sha']}):")
    flags = []

    def delta(label, a, b, floor, higher_is_worse=True):
        if a is None or b is None or a == 0:
            return
        d = (b - a) / a * 100
        worse = d > 20 if higher_is_worse else d < -20
        big = abs(b - a) >= floor
        mark = "  << REGRESSION" if worse and big else ""
        print(f"  {label:<34}{a:>12.2f} -> {b:>12.2f}  {d:+7.1f}%{mark}")
        if mark:
            flags.append(f"{label}: {a:.2f} -> {b:.2f} ({d:+.1f}%)")

    for n, e in res["endpoints"].items():
        o = old["endpoints"].get(n)
        if not o:
            continue
        delta(f"{n} p99 ms", o["p99_ms"], e["p99_ms"], 2.0)
        delta(f"{n} rps", o["rps"], e["rps"], 1e18, higher_is_worse=False)  # shown, not flagged
        delta(f"{n} peak RSS KB", o.get("peak_rss_kb"), e.get("peak_rss_kb"), 2048)
        delta(f"{n} peak anon KB", o.get("peak_anon_kb"), e.get("peak_anon_kb"), 2048)
    for k, label, floor in (("sse", "fanout_spread_p99_ms", 2.0), ("snapshot", "settled_to_files_median_ms", 50.0)):
        if res.get(k) and old.get(k):
            delta(f"{k} {label}", old[k].get(label), res[k].get(label), floor)
    for ph in ("start", "after_load", "after_soak", "end"):
        if ph in res["process"] and ph in old.get("process", {}):
            delta(f"process {ph} RSS KB", old["process"][ph]["rss_kb"], res["process"][ph]["rss_kb"], 2048)
            delta(f"process {ph} HWM KB", old["process"][ph]["hwm_kb"], res["process"][ph]["hwm_kb"], 2048)
            delta(f"process {ph} anon KB", old["process"][ph].get("anon_kb"), res["process"][ph].get("anon_kb"), 2048)
    if res.get("soak") and old.get("soak"):
        # Shown, not flagged: the mix's tail is the slowest endpoint's, already flagged above.
        delta("soak p99 ms", old["soak"]["p99_ms"], res["soak"]["p99_ms"], 1e18)
    delta("binary bytes", old.get("binary_bytes"), res.get("binary_bytes"), 1e18)
    if flags:
        print(f"\n{len(flags)} regression(s) over 20%:")
        for f in flags:
            print("  - " + f)
    else:
        print("\nno regressions over 20% in p99 or RSS")
    return flags


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    for a in ("port", "pid", "duration", "concurrency", "soak", "sse_clients", "turns", "terms", "quick", "ready_ms"):
        ap.add_argument("--" + a.replace("_", "-"), type=int, required=True)
    for a in ("scratch", "bin", "sessions_json", "repo", "tool", "out_dir", "gen_secs"):
        ap.add_argument("--" + a.replace("_", "-"), required=True)
    o = ap.parse_args()
    port, pid = o.port, o.pid
    facts = json.load(open(o.sessions_json))
    tool = o.tool
    if tool == "auto":
        tool = "oha" if shutil.which("oha") else "hey" if shutil.which("hey") else "python"
    print(f"== load generator: {tool}" + ("" if tool != "python" else " (built-in; oha/hey not installed)"))

    q = urllib.parse.quote
    repo = o.repo
    small_cwd = facts["cwds"][1]
    endpoints = {
        "version": "/api/version",
        "sessions": "/api/sessions",
        "projects": "/api/projects",
        "outline": f"/api/sessions/outline?path={q(facts['large_session'])}",
        "usage": "/api/usage",
        "files_list": f"/api/files/list?root={q(repo)}&dir=src/mod00/pkg00",
        "files_read": f"/api/files/read?root={q(repo)}&path=big.log",
        "files_search": f"/api/files/search?root={q(repo)}&q=await",
    }

    sampler = Sampler(pid)
    sampler.start()
    time.sleep(0.5)
    sha = git("rev-parse", "--short", "HEAD")
    res = {"date": datetime.datetime.now().strftime("%Y-%m-%dT%H-%M-%S"), "git_sha": sha,
           "git_dirty": bool(git("status", "--porcelain", "--untracked-files=no")),
           "config": {"sessions": facts["sessions"], "repo_files": None,
                      "concurrency": o.concurrency, "duration": o.duration, "soak": o.soak, "tool": tool, "quick": bool(o.quick),
                      "sse_clients": o.sse_clients, "turns": o.turns, "terms": o.terms},
           "binary_bytes": os.path.getsize(o.bin),
           "dataset": {"sessions": facts["sessions"], "session_bytes": facts["bytes"], "large_session_entries": facts["large_entries"],
                       "gen_secs": float(o.gen_secs)},
           "loadavg_start": [round(x, 2) for x in os.getloadavg()], "cpus": os.cpu_count(),
           "startup": {"ready_ms": o.ready_ms}, "process": {"start": snap(pid)}, "endpoints": {}}
    repo_facts = os.path.join(o.scratch, "repo.json")
    res["config"]["repo_files"] = json.load(open(repo_facts))["files"] if os.path.exists(repo_facts) else None

    # Cold: the first request of each, before any cache is warm.
    print("== cold requests")
    for name, path in endpoints.items():
        ms, status, size = timed_get(port, path)
        res["endpoints"][name] = {"cold_ms": round(ms, 1), "cold_status": status}
        print(f"  {name:<14}{ms:9.1f} ms  {status}  {size / 1024:.0f} KB")
        if status >= 400:
            print(f"  !! {name} answered {status}", file=sys.stderr)

    # Terminals first, while the heap is small and quiet: the per-terminal
    # RSS delta is lost in allocator noise after the load phases.
    if o.terms:
        print(f"== terminals: {o.terms}")
        try:
            res["terminals"] = terminals(port, pid, facts["cwds"][2], o.terms, sampler)
        except Exception as e:
            res["terminals"] = {"error": repr(e)}

    ctx = mp.get_context("spawn")
    with ctx.Pool(o.concurrency) as pool:
        pool.map(time.sleep, [0] * o.concurrency)  # start the workers before timing
        print(f"== load: {o.duration} s each, {o.concurrency} connections")
        for name, path in endpoints.items():
            sampler.phase = "load:" + name
            if tool == "oha":
                r = load_oha(port, path, o.duration, o.concurrency)
            elif tool == "hey":
                r = load_hey(port, path, o.duration, o.concurrency)
            else:
                r = load_python(pool, port, [path], o.duration, o.concurrency)
            sampler.phase = "between"
            r.update(sampler.peak("load:" + name))
            res["endpoints"][name].update(r)
            print(f"  {name:<14}{r['rps']:9.1f} rps  p50 {r['p50_ms']} ms  p99 {r['p99_ms']} ms  errors {r['errors']}")
        res["process"]["after_load"] = snap(pid)

        print(f"== SSE fan-out: {o.sse_clients} clients on one chat")
        res["sse"] = sse_fanout(port, small_cwd, o.sse_clients, 400, sampler)
        print(f"== git snapshot per turn: {o.turns} turn(s) in the {res['config']['repo_files']}-file repo")
        res["snapshot"] = snapshot_turns(port, repo, o.turns, sampler)
        if o.soak:
            print(f"== soak: {o.soak} s of the mix")
            mix = [p for n, p in endpoints.items() if n != "version"]
            res["soak"] = soak(pool, port, pid, mix, o.soak, o.concurrency, sampler)
            time.sleep(2)
            res["process"]["after_soak"] = snap(pid)
    time.sleep(1)
    res["process"]["end"] = snap(pid)
    sampler.stop.set()

    os.makedirs(o.out_dir, exist_ok=True)
    out = os.path.join(o.out_dir, f"{res['date']}-{sha}.json")
    flags = None
    print_table(res)
    flags = compare(res, o.out_dir, out)
    res["regressions"] = flags
    with open(out, "w") as f:
        json.dump(res, f, indent=1)
    print(f"\nwrote {out}")


if __name__ == "__main__":
    main()
