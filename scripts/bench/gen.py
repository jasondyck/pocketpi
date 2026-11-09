#!/usr/bin/env python3
"""Synthetic history for scripts/bench.sh: pi session files and a big git repo.

    gen.py sessions <sessions_dir> <projects_root> <count>   # prints JSON facts
    gen.py repo <dir> <files>

Sessions are written the way pi writes them (src/sessions.rs, src/outline.rs
and src/usage.rs read them): one folder per cwd under the sessions dir, a
`{"type":"session",...}` header, then compact `{"type":"message",...}`
entries chained by parentId, with user / assistant (provider, model, usage,
cost) / toolResult messages, the odd session_info and usage entry. Sizes are
skewed like real history: most chats are short, some long, a few huge (2000+
entries). Everything is seeded, so every run benches the same data.
"""
import json
import os
import random
import subprocess
import sys
import time

WORDS = ("the of and to in is that for it as was with be by on not he this are or his from at which but have an they "
         "you were her she there would their we him been has when who will no more if out so up said what its about "
         "than into them can only other time new some could these two may first then do any like my now over such our "
         "man me even most made after also did many off before must well back through years much where your way down "
         "should because each just those people how too little state good very make world still see own men work long "
         "fn struct impl async await tokio axum serde json path file error result option match let mut self crate").split()

PROVIDERS = [("anthropic", "claude-sonnet-5"), ("opencode-go", "glm-5.2"), ("openai-codex", "gpt-5.5"),
             ("deepseek", "deepseek-v4"), ("openrouter", "qwen-4-coder")]


def words(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n))


def iso(ms):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms / 1000)) + f".{ms % 1000:03d}Z"


def compact(rec):
    return json.dumps(rec, separators=(",", ":")) + "\n"


def entry_count(rng, i):
    """Skewed: a few huge (2000-4000), ~4% long (300-1200), the rest 6-120."""
    if i < 4:
        return rng.randint(2000, 4000)
    r = rng.random()
    if r < 0.04:
        return rng.randint(300, 1200)
    if r < 0.30:
        return rng.randint(40, 120)
    return rng.randint(6, 40)


def write_session(path, cwd, n_entries, start_ms, rng, sid):
    lines = [compact({"type": "session", "version": 3, "id": sid, "timestamp": iso(start_ms), "cwd": cwd})]
    parent = None
    ms = start_ms
    k = 0
    turn = 0
    while k < n_entries:
        # One turn: user prompt, 0-3 tool rounds, a final reply.
        turn += 1
        ms += rng.randint(20_000, 600_000)
        uid = f"{sid[:6]}{k:05x}"
        lines.append(compact({"type": "message", "id": uid, "parentId": parent, "timestamp": iso(ms),
                              "message": {"role": "user", "content": [{"type": "text", "text": words(rng, rng.randint(8, 60))}],
                                          "timestamp": ms}}))
        parent, k = uid, k + 1
        provider, model = PROVIDERS[turn % len(PROVIDERS)]
        for _ in range(rng.choice((0, 0, 1, 2, 3))):
            if k >= n_entries:
                break
            ms += rng.randint(1000, 30_000)
            aid, rid = f"{sid[:6]}{k:05x}", f"{sid[:6]}{k + 1:05x}"
            call = {"type": "toolCall", "id": f"c{k}", "name": rng.choice(("bash", "read", "edit")),
                    "arguments": {"command": words(rng, 6), "path": "src/" + rng.choice(WORDS) + ".rs"}}
            lines.append(compact({"type": "message", "id": aid, "parentId": parent, "timestamp": iso(ms), "message": {
                "role": "assistant", "content": [{"type": "thinking", "thinking": words(rng, rng.randint(10, 80))}, call],
                "provider": provider, "model": model,
                "usage": {"input": rng.randint(2000, 90000), "output": rng.randint(20, 900), "cacheRead": rng.randint(0, 80000),
                          "cacheWrite": rng.randint(0, 3000), "totalTokens": 0,
                          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": round(rng.random() * 0.05, 5)}},
                "stopReason": "toolUse", "timestamp": ms}}))
            lines.append(compact({"type": "message", "id": rid, "parentId": aid, "timestamp": iso(ms + 50), "message": {
                "role": "toolResult", "toolCallId": f"c{k}", "toolName": call["name"],
                "content": [{"type": "text", "text": words(rng, rng.randint(30, 600))}], "isError": False, "timestamp": ms + 50}}))
            parent, k = rid, k + 2
        ms += rng.randint(1000, 30_000)
        aid = f"{sid[:6]}{k:05x}"
        lines.append(compact({"type": "message", "id": aid, "parentId": parent, "timestamp": iso(ms), "message": {
            "role": "assistant", "content": [{"type": "thinking", "thinking": words(rng, rng.randint(5, 50))},
                                             {"type": "text", "text": words(rng, rng.randint(20, 250))}],
            "provider": provider, "model": model,
            "usage": {"input": rng.randint(2000, 90000), "output": rng.randint(50, 2000), "cacheRead": rng.randint(0, 80000),
                      "cacheWrite": rng.randint(0, 3000), "totalTokens": 0,
                      "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": round(rng.random() * 0.08, 5)}},
            "stopReason": "stop", "timestamp": ms}}))
        parent, k = aid, k + 1
        if turn == 2 and rng.random() < 0.3:
            lines.append(compact({"type": "session_info", "id": f"{sid[:6]}i{k:04x}", "parentId": parent,
                                  "timestamp": iso(ms), "name": words(rng, 4)}))
    with open(path, "w") as f:
        f.writelines(lines)
    os.utime(path, (ms / 1000, ms / 1000))
    return ms


def sessions(sessions_dir, projects_root, count, repo_cwd=None):
    rng = random.Random(1234)
    cwds = [os.path.join(projects_root, f"proj-{i:02d}") for i in range(20)]
    if repo_cwd:
        cwds[0] = repo_cwd
    for c in cwds:
        os.makedirs(c, exist_ok=True)
    # Spread over the last ~90 days, ending an hour ago (deterministic per day).
    now = int(time.time() * 1000) - 3_600_000
    biggest = (0, None)
    total_bytes = 0
    for i in range(count):
        cwd = cwds[0] if i < 4 else rng.choice(cwds)  # the huge ones go to the repo project
        folder = os.path.join(sessions_dir, "--" + cwd.strip("/").replace("/", "-") + "--")
        os.makedirs(folder, exist_ok=True)
        sid = f"{rng.getrandbits(64):016x}-{i:05d}"
        start = now - rng.randint(0, 90 * 86_400_000)
        n = entry_count(rng, i)
        path = os.path.join(folder, f"{start}_{sid}.jsonl")
        write_session(path, cwd, n, start, rng, sid)
        size = os.path.getsize(path)
        total_bytes += size
        if n > biggest[0]:
            biggest = (n, path)
    return {"sessions": count, "cwds": cwds, "bytes": total_bytes, "large_session": biggest[1], "large_entries": biggest[0]}


def repo(d, files):
    rng = random.Random(99)
    os.makedirs(d, exist_ok=True)
    per_dir = 100
    for i in range(files):
        sub = os.path.join(d, "src", f"mod{i // (per_dir * 20):02d}", f"pkg{(i // per_dir) % 20:02d}")
        if i % per_dir == 0:
            os.makedirs(sub, exist_ok=True)
        name = f"{rng.choice(WORDS)}_{i:05d}.{rng.choice(('rs', 'ts', 'py', 'md', 'json'))}"
        with open(os.path.join(sub, name), "w") as f:
            f.write("\n".join(words(rng, 10) for _ in range(rng.randint(5, 40))) + "\n")
    # One big text file for /api/files/read (~6 MB, 100k lines).
    with open(os.path.join(d, "big.log"), "w") as f:
        for n in range(100_000):
            f.write(f"{n:06d} {words(rng, 9)}\n")
    with open(os.path.join(d, ".gitignore"), "w") as f:
        f.write("target/\n")
    env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    git = ["git", "-c", "user.name=bench", "-c", "user.email=bench@localhost", "-c", "commit.gpgsign=false"]
    subprocess.run(git + ["init", "-q", "-b", "main"], cwd=d, check=True, env=env)
    subprocess.run(git + ["add", "-A"], cwd=d, check=True, env=env)
    subprocess.run(git + ["commit", "-q", "-m", "synthetic"], cwd=d, check=True, env=env)
    return {"files": files + 2, "big_file": "big.log"}


if __name__ == "__main__":
    what = sys.argv[1]
    if what == "sessions":
        repo_cwd = sys.argv[5] if len(sys.argv) > 5 else None
        print(json.dumps(sessions(sys.argv[2], sys.argv[3], int(sys.argv[4]), repo_cwd)))
    elif what == "repo":
        print(json.dumps(repo(sys.argv[2], int(sys.argv[3]))))
    else:
        sys.exit(f"unknown: {what}")
