#!/usr/bin/env python3
"""ACP agent 鉴权自检:读取 claude-acp.json 的 env，在极简环境(模拟 GUI app 的 launchd 环境)里
跑 initialize→session/new→session/prompt，确认能否打通。不打印 token。

用法:  python3 Scripts/acp_check.py
"""
import subprocess, json, threading, time, os, sys

cfg_path = os.path.expanduser("~/Library/Application Support/AgentDeck/Agents/claude-acp.json")
cfg = json.load(open(cfg_path))
agent_env = cfg.get("env", {})
if "<" in agent_env.get("ANTHROPIC_AUTH_TOKEN", ""):
    print("✗ 还没填 token：编辑", cfg_path, "把 ANTHROPIC_AUTH_TOKEN 改成你的 tp- token")
    sys.exit(1)

# 极简环境(逼近 GUI app)+ agent 自带 env
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
       "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"}
env.update(agent_env)

cmd = [("/opt/homebrew/bin/npx" if os.path.exists("/opt/homebrew/bin/npx") else "npx")] + cfg["args"]
p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     text=True, bufsize=1, env=env)
st = {"sid": None, "done": False, "out": "", "err": None}

def send(o): p.stdin.write(json.dumps(o) + "\n"); p.stdin.flush()
def rdr():
    for line in p.stdout:
        try: m = json.loads(line)
        except: continue
        if "method" in m and "id" in m:
            send({"jsonrpc": "2.0", "id": m["id"], "result": {}}); continue
        if m.get("method") == "session/update":
            u = m["params"].get("update", {})
            if u.get("sessionUpdate") == "agent_message_chunk":
                st["out"] += u.get("content", {}).get("text", "")
        if m.get("id") == 2 and "result" in m: st["sid"] = m["result"]["sessionId"]
        if m.get("id") == 3:
            if "error" in m: st["err"] = m["error"]
            st["done"] = True
threading.Thread(target=rdr, daemon=True).start()

time.sleep(1)
send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": True}, "terminal": False}}})
time.sleep(2)
send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": "/tmp", "mcpServers": []}})
for _ in range(40):
    if st["sid"]: break
    time.sleep(0.2)
if st["sid"]:
    send({"jsonrpc": "2.0", "id": 3, "method": "session/prompt",
          "params": {"sessionId": st["sid"], "prompt": [{"type": "text", "text": "reply with: OK"}]}})
for _ in range(80):
    if st["done"]: break
    time.sleep(0.5)
p.terminate()

print(f"base_url = {agent_env.get('ANTHROPIC_BASE_URL')}")
print(f"model    = {agent_env.get('ANTHROPIC_MODEL')}")
if st["err"]:
    print("✗ 失败：", json.dumps(st["err"], ensure_ascii=False))
elif st["out"].strip():
    print("✓ 打通：", repr(st["out"][:80]))
    print("  → AgentDeck 里这个 ACP agent 能用了，重启 app 即可")
else:
    print("✗ 无输出(未收到答案)")
