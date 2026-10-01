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

Spec 004 adds answers chosen by the request's "format" schema (the properties it asks for):
  schema with "screen_kind"  -> a valid classification (calendar_week, confidence 0.9)
  schema with "findings"     -> valid findings that cite lines 1 and 2
  any other schema           -> the test answer above
and these modes (all other modes still apply to every call):
  extract                  same as ok: valid classification and findings
  extract-bad-citation     one finding cites line 9999, which does not exist
  extract-empty            findings is an empty list
  classify-unsure          classification is "other" with confidence 0.2

Spec 005 adds the two calls reconciliation makes (all modes except ok-only ones apply as for /api/chat):
  POST /api/embed      one 8-dimension vector per input: counts of the lowercased text's character trigrams
                       hashed into 8 buckets, then normalised (equal texts give equal vectors, a truncated
                       title is close to the full one)
  POST /api/generate   raw reranker call: answers "yes" when the Query and Document titles share their first
                       8 normalised characters, else "no", with log probabilities in "logprobs"

Options: --no-vision (only a text model is listed), --no-capabilities (models carry no
"capabilities" key, so the app must ask /api/show), --thinking (the vision model also lists
"thinking"). Standard library only. Listens on 127.0.0.1 only.
"""
import argparse
import json
import sys
import math
import re
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


def classification(unsure=False):
    return json.dumps({"screen_kind": "other" if unsure else "calendar_week",
                       "kind_confidence": 0.2 if unsure else 0.9,
                       "application": "Fake Calendar", "platform_look": "macos",
                       "remote_session": {"is_remote": False, "client": ""},
                       "theme": "light", "calendar_name": "Work"})


def findings(mode):
    items = [] if mode == "extract-empty" else [
        {"kind": "appointment", "title": "Team sync", "cited_lines": [1, 2],
         "start_text": "10:00", "end_text": "11:30", "all_day": False, "people": []},
        {"kind": "task", "title": "Send the report", "cited_lines": [2],
         "due_text": "Friday", "all_day": False, "people": ["Anna"]}]
    if mode == "extract-bad-citation":
        items.append({"kind": "appointment", "title": "Ghost meeting", "cited_lines": [9999],
                      "start_text": "12:00", "all_day": False, "people": []})
    return json.dumps({"findings": items})


def answer_for(body, mode):
    fmt = body.get("format")
    props = fmt.get("properties", {}) if isinstance(fmt, dict) else {}
    if "screen_kind" in props:
        return classification(unsure=(mode == "classify-unsure"))
    if "findings" in props:
        return findings(mode)
    return valid_answer()


def valid_answer():
    return json.dumps({"description": "A calendar with a meeting called Team sync at 10:00.",
                       "contains_text": True, "text_sample": "Team sync 10:00"})


def embedding(text):
    text = re.sub(r"^query: ", "", text.lower())
    vector = [0.0] * 8
    for i in range(max(len(text) - 2, 1)):
        vector[sum(ord(c) for c in text[i:i + 3]) % 8] += 1.0
    norm = math.sqrt(sum(x * x for x in vector)) or 1.0
    return [x / norm for x in vector]


def normalised(title):
    return re.sub(r"[^a-z0-9]", "", title.lower())


def rerank_answer(prompt):
    query = re.search(r"<Query>: (.*?)\n<Document>: (.*?)<\|im_end\|>", prompt, re.S)
    if not query:
        return "no", -0.1
    a, b = normalised(query.group(1))[:8], normalised(query.group(2))[:8]
    return ("yes", -0.2) if a and a == b else ("no", -0.3)


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
        if self.path in ("/api/embed", "/api/generate"):
            with lock:
                chat_calls += 1
                call = chat_calls
            if args.mode == "slow":
                time.sleep(args.delay)
            if args.mode == "error" or (args.mode == "flaky" and call % 2 == 1):
                self.reply(500, {"error": "fake server error"})
                return
            if self.path == "/api/embed":
                inputs = body.get("input", [])
                inputs = [inputs] if isinstance(inputs, str) else inputs
                self.reply(200, {"model": body.get("model"), "embeddings": [embedding(t) for t in inputs]})
            else:
                token, logprob = rerank_answer(body.get("prompt", ""))
                other = "no" if token == "yes" else "yes"
                self.reply(200, {"model": body.get("model"), "response": token, "done": True,
                                 "logprobs": [{"token": token, "logprob": logprob,
                                               "top_logprobs": [{"token": token, "logprob": logprob},
                                                                {"token": other, "logprob": -3.0}]}]})
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
        content = "this is definitely not json" if args.mode == "invalid" else answer_for(body, args.mode)
        self.reply(200, {"model": body.get("model"), "done": True, "done_reason": "stop",
                         "message": {"role": "assistant", "content": content},
                         "total_duration": 1_000_000_000, "load_duration": 1_000_000,
                         "prompt_eval_duration": 100_000_000, "eval_count": 20})


def main():
    global args
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=11999)
    parser.add_argument("--mode", choices=["ok", "invalid", "slow", "error", "flaky", "hang", "extract", "extract-bad-citation",
                                              "extract-empty", "classify-unsure"], default="ok")
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
