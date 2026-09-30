#!/usr/bin/env python3
"""A stand-in for the Ollama server, for testing Memorri's failure cases without the real model.

    python3 scripts/fake-ollama.py --port 11999 --mode ok|invalid|slow|error|flaky|hang

Modes for POST /api/chat:
  ok       a valid answer for the test schema (description, contains_text, text_sample)
  invalid  text that is not valid JSON
  slow     waits --delay seconds (default 5), then a valid answer
  error    HTTP 500
  flaky    HTTP 500 on odd calls, a valid answer on even calls
  hang     every endpoint (including /api/version) never answers within a minute

Options: --no-vision (only a text model is listed), --no-capabilities (models carry no
"capabilities" key, so the app must ask /api/show), --thinking (the vision model also lists
"thinking"). Standard library only. Listens on 127.0.0.1 only.
"""
import argparse
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

args = None
chat_calls = 0
lock = threading.Lock()


def models():
    vision_caps = ["completion", "vision"] + (["thinking"] if args.thinking else [])
    entries = [("fake-text:1b", ["completion"])]
    if not args.no_vision:
        entries.insert(0, ("fake-vision:1b", vision_caps))
    out = []
    for name, caps in entries:
        entry = {"name": name, "model": name, "size": 1, "digest": "fake", "details": {}}
        if not args.no_capabilities:
            entry["capabilities"] = caps
        out.append(entry)
    return out


def valid_answer():
    return json.dumps({"description": "A calendar with a meeting called Team sync at 10:00.",
                       "contains_text": True, "text_sample": "Team sync 10:00"})


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        pass

    def reply(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def note(self, what):
        print(f"{time.strftime('%H:%M:%S')} {what}", flush=True)

    def do_GET(self):
        self.note(f"GET {self.path}")
        if args.mode == "hang":
            time.sleep(60)
        if self.path == "/api/version":
            self.reply(200, {"version": "0.0.0-fake"})
        elif self.path == "/api/tags":
            self.reply(200, {"models": models()})
        else:
            self.reply(404, {"error": "not found"})

    def do_POST(self):
        global chat_calls
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        self.note(f"POST {self.path}")
        if args.mode == "hang":
            time.sleep(60)
        if self.path == "/api/show":
            name = body.get("model", "")
            entry = next((m for m in models() if m["name"] == name), None)
            caps = ["completion", "vision"] + (["thinking"] if args.thinking else []) if name == "fake-vision:1b" else ["completion"]
            self.reply(200 if entry else 404, {"capabilities": caps} if entry else {"error": "model not found"})
            return
        if self.path != "/api/chat":
            self.reply(404, {"error": "not found"})
            return
        with lock:
            chat_calls += 1
            call = chat_calls
        if args.mode == "slow":
            time.sleep(args.delay)
        if args.mode == "error" or (args.mode == "flaky" and call % 2 == 1):
            self.reply(500, {"error": "fake server error"})
            return
        content = "this is definitely not json" if args.mode == "invalid" else valid_answer()
        self.reply(200, {"model": body.get("model"), "done": True, "done_reason": "stop",
                         "message": {"role": "assistant", "content": content},
                         "total_duration": 1_000_000_000, "load_duration": 1_000_000,
                         "prompt_eval_duration": 100_000_000, "eval_count": 20})


def main():
    global args
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=11999)
    parser.add_argument("--mode", choices=["ok", "invalid", "slow", "error", "flaky", "hang"], default="ok")
    parser.add_argument("--delay", type=float, default=5.0)
    parser.add_argument("--no-vision", action="store_true")
    parser.add_argument("--no-capabilities", action="store_true")
    parser.add_argument("--thinking", action="store_true")
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"fake Ollama on 127.0.0.1:{args.port} mode={args.mode}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
