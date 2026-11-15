"""Leaked-value hash scan (issue #135).

usage: leaked-hash-scan.py <repo-dir> <hashes-file>

Hashes every token of every tracked text file (split on whitespace, quotes,
brackets and also on '=' and ':') and compares with the sha256 list. Prints
only repo-relative file names, never tokens. Exit 0 clean, 1 hit, 2 error.
"""
import hashlib
import re
import subprocess
import sys

repo, hashes_file = sys.argv[1], sys.argv[2]
try:
    wanted = {
        line.strip().lower()
        for line in open(hashes_file, encoding="utf-8")
        if line.strip() and not line.startswith("#")
    }
    files = subprocess.run(
        ["git", "-C", repo, "ls-files", "-z"], check=True, capture_output=True
    ).stdout.split(b"\0")
except Exception as exc:  # fail closed
    print("ERROR: %s" % type(exc).__name__, file=sys.stderr)
    sys.exit(2)

split = re.compile(r"[\s'\"`,;()<>\[\]{}]+")
hits = []
for raw in files:
    if not raw:
        continue
    name = raw.decode("utf-8", "replace")
    try:
        data = open("%s/%s" % (repo, name), "rb").read()
    except OSError:
        continue
    if b"\0" in data[:4096] or len(data) > 5_000_000:
        continue
    text = data.decode("utf-8", "replace")
    found = False
    for tok in split.split(text):
        cands = {tok}
        cands.update(re.split(r"[=:]", tok))
        for c in cands:
            if 6 <= len(c) <= 200 and hashlib.sha256(c.encode()).hexdigest() in wanted:
                found = True
                break
        if found:
            break
    if found:
        hits.append(name)

for h in hits:
    print(h)
sys.exit(1 if hits else 0)
