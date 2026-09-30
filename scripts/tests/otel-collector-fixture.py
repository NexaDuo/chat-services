"""Synthetic OTLP fixtures only; called by test-otel-collector.sh."""
import json
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

receiver, prometheus, tempo, output = sys.argv[1:]


def request(url, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=2) as response:
        return response.read().decode()


def eventually(fn):
    deadline = time.monotonic() + 20
    while True:
        try:
            return fn()
        except (AssertionError, urllib.error.URLError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(0.5)


# Same timestamp/value on old and new makes the entire contract comparable.
stamp = "1700000001000000000"
attrs = [{"key": "account_id", "value": {"stringValue": "synthetic-219"}},
         {"key": "kind", "value": {"stringValue": "prompt"}}]
metrics = []
for name, unit in [("middleware_dify_tokens_total", ""),
                   ("fixture.calls", ""), ("fixture.duration", "s")]:
    metrics.append({"name": name, "unit": unit, "sum": {
        "aggregationTemporality": 2, "isMonotonic": True,
        "dataPoints": [{"attributes": attrs, "startTimeUnixNano": "1700000000000000000",
                        "timeUnixNano": stamp, "asInt": "7"}]}})
response = json.loads(request(receiver + "/v1/metrics", {
    "resourceMetrics": [{"scopeMetrics": [{"scope": {"name": "w2c", "version": "1"},
                                          "metrics": metrics}]}]}))
assert not response.get("partialSuccess"), response


def scrape():
    text = request(prometheus + "/metrics")
    names = ["dify_middleware_dify_tokens_total", "dify_fixture_calls_total",
             "dify_fixture_duration_seconds_total"]
    for name in names:
        assert f"# TYPE {name} counter\n" in text, text
        matches = re.findall(r"^" + name + r"\{([^}]*)\} 7 1700000001000$", text, re.M)
        assert len(matches) == 1, text
        labels = dict(re.findall(r'(\w+)="([^"]*)"', matches[0]))
        labels = {k: v for k, v in labels.items() if not k.startswith("otel_scope_")}
        assert labels == {"account_id": "synthetic-219", "kind": "prompt"}, labels
    # Compare all emitted lines, including absence of accidental extra series.
    # Only normalization: otel_scope_* labels (added by newer exporters) are
    # stripped, mirroring the labeldrop in observability/prometheus/prometheus.yml.
    text = re.sub(r',?otel_scope_[a-z_]+="[^"]*"', "", text).replace("{,", "{")
    return "\n".join(sorted(text.splitlines())) + "\n"


with open(output, "w") as file:
    file.write(eventually(scrape))
trace_id = uuid.uuid4().hex
span_id = uuid.uuid4().hex[:16]
now = time.time_ns()
response = json.loads(request(receiver + "/v1/traces", {
    "resourceSpans": [{"resource": {"attributes": [
        {"key": "service.name", "value": {"stringValue": "w2c-synthetic"}}]},
        "scopeSpans": [{"scope": {"name": "w2c"}, "spans": [{
            "traceId": trace_id, "spanId": span_id, "name": "w2c-terminal-trace",
            "kind": 1, "startTimeUnixNano": str(now),
            "endTimeUnixNano": str(now + 1000000), "attributes": attrs}]}]}]}))
assert not response.get("partialSuccess"), response


def trace_arrived():
    trace = json.loads(request(tempo + "/api/traces/" + trace_id))
    spans = [span for batch in trace.get("batches", [])
             for scope in batch.get("scopeSpans", []) for span in scope.get("spans", [])]
    assert any(span["name"] == "w2c-terminal-trace" and
               any(a["key"] == "account_id" and a["value"].get("stringValue") == "synthetic-219"
                   for a in span.get("attributes", [])) for span in spans), trace


eventually(trace_arrived)
print("PASS: exact Prometheus contract and trace retrieved from Tempo")
