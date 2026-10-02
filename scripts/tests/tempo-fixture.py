"""Synthetic trace contract for test-tempo.sh; no third-party dependencies."""
import base64
import json
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

mode, container, fixture = sys.argv[1:]


def url(port):
    address = subprocess.check_output(
        ["docker", "port", container, f"{port}/tcp"], text=True).strip()
    return "http://" + address


def request(endpoint, body=None):
    req = urllib.request.Request(endpoint, data=body, headers={
        "Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=3) as response:
        return response.read()


def eventually(fn):
    deadline = time.monotonic() + 30
    while True:
        try:
            return fn()
        except (AssertionError, urllib.error.URLError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.5)


http = url(3200)
if mode.startswith("write"):
    trace = uuid.uuid4().hex
    span = uuid.uuid4().hex[:16]
    now = time.time_ns()
    payload = {"resourceSpans": [{"resource": {"attributes": [
        {"key": "service.name", "value": {"stringValue": "w4a-synthetic"}}]},
        "scopeSpans": [{"spans": [{"traceId": trace, "spanId": span,
            "name": "w4a-storage-upgrade", "kind": 2,
            "startTimeUnixNano": str(now), "endTimeUnixNano": str(now + 1000000)}]}]}]}
    result = json.loads(request(url(4318) + "/v1/traces", json.dumps(payload).encode()))
    assert not result.get("partialSuccess"), result
    Path(fixture).write_text(json.dumps({"trace": trace, "span": span}))
else:
    data = json.loads(Path(fixture).read_text())
    trace, span = data["trace"], data["span"]


def retrieve():
    result = json.loads(request(http + "/api/traces/" + trace))
    text = json.dumps(result)
    assert "w4a-storage-upgrade" in text, text
    assert span in text or base64.b64encode(bytes.fromhex(span)).decode() in text, text


eventually(retrieve)


def search():
    query = urllib.parse.urlencode({"q": '{ resource.service.name = "w4a-synthetic" }'})
    result = json.loads(request(http + "/api/search?" + query))
    # Tempo drops leading zeros from trace IDs in search results.
    assert trace in [t["traceID"].rjust(32, "0") for t in result.get("traces", [])], result


if mode.startswith("write"):
    eventually(search)
if mode == "write":
    request(http + "/flush", b"")
print(f"PASS: {mode} trace by ID" + (" and TraceQL" if mode.startswith("write") else ""))
