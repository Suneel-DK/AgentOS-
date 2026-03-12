#!/usr/bin/env python3
"""
AgentOS Template — Summarizer Agent
Reads URLs or text from stdin and summarizes them using Ollama.
Send input via: POST /agents/<id>/input  {"text": "https://..."}
"""

import json
import sys
import urllib.request

OLLAMA_URL = "http://localhost:11434/api/generate"
MODEL = "llama3.2:3b"

print(f"[summarizer] Summarizer agent started — model: {MODEL}", flush=True)
print("[summarizer] Send text to summarize via POST /agents/<id>/input", flush=True)


def summarize(text: str) -> str:
    prompt = f"Summarize the following in 3-5 bullet points. Be concise.\n\n{text[:4000]}"
    payload = json.dumps({"model": MODEL, "prompt": prompt, "stream": False}).encode()
    req = urllib.request.Request(
        OLLAMA_URL, data=payload, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.loads(resp.read())
        return data.get("response", "").strip()


for line in sys.stdin:
    text = line.strip()
    if not text:
        continue
    print(f"[summarizer] Summarizing: {text[:80]}...", flush=True)
    try:
        result = summarize(text)
        print(f"[summarizer] Summary:\n{result}", flush=True)
    except Exception as e:
        print(f"[summarizer] Error: {e}", flush=True)
