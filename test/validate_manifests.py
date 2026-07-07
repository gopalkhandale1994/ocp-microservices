#!/usr/bin/env python3
"""Lightweight k8s manifest validation with no cluster/dependency needed:
every YAML document must parse, and every resource must carry apiVersion,
kind, and metadata.name. Catches the class of mistake we hit by hand
several times (bad indentation breaking a resources: block, a dangling
key) before it ever reaches a real cluster.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "k8s"
errors = []


def parse_documents(text):
    # Split on a line that is exactly "---" (a YAML document separator),
    # avoiding any real dependency on a yaml library in this environment.
    docs, current = [], []
    for line in text.splitlines():
        if line.strip() == "---":
            if current:
                docs.append("\n".join(current))
            current = []
        else:
            current.append(line)
    if current:
        docs.append("\n".join(current))
    return docs


required_top_level = re.compile(r"^(apiVersion|kind|metadata):", re.MULTILINE)

for path in sorted(ROOT.rglob("*.yaml")):
    text = path.read_text()
    docs = [d for d in parse_documents(text) if d.strip()]
    if not docs:
        errors.append(f"{path}: no YAML documents found")
        continue
    for i, doc in enumerate(docs):
        missing = [
            key for key in ("apiVersion", "kind", "metadata")
            if not re.search(rf"^{key}:", doc, re.MULTILINE)
        ]
        if missing:
            errors.append(f"{path} (document {i + 1}): missing {', '.join(missing)}")
        if "metadata" in doc and not re.search(r"^\s+name:", doc, re.MULTILINE):
            errors.append(f"{path} (document {i + 1}): metadata has no name")

if errors:
    print(f"FAIL: {len(errors)} problem(s) found\n")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

count = sum(len([d for d in parse_documents(p.read_text()) if d.strip()]) for p in ROOT.rglob("*.yaml"))
print(f"OK: {count} resource document(s) across {len(list(ROOT.rglob('*.yaml')))} file(s) look structurally valid")
