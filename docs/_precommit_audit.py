# -*- coding: utf-8 -*-
"""Pre-commit audit: python syntax + privacy/leak scan."""
import ast, os, re, sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

ROOT = r"D:\research\akd prediction\akd_prediction_code"
syntax_bad, privacy_hits = [], []

PRIV_PATTERNS = [
    (re.compile(r"password\s*=\s*['\"][^'\"]+['\"]", re.I), "hardcoded password"),
    (re.compile(r"passwd\s*=\s*['\"][^'\"]+['\"]", re.I), "hardcoded passwd"),
    (re.compile(r"\b\d{17}[\dXx]\b"), "possible Chinese ID number"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS key pattern"),
    (re.compile(r"api[_-]?key\s*=\s*['\"][^'\"]{8,}['\"]", re.I), "hardcoded api key"),
    (re.compile(r"token\s*=\s*['\"][^'\"]{20,}['\"]", re.I), "hardcoded token"),
    (re.compile(r"\b1[3-9]\d{9}\b"), "possible CN mobile number"),
]

for dirpath, _, files in os.walk(ROOT):
    if ".git" in dirpath:
        continue
    for fn in files:
        p = os.path.join(dirpath, fn)
        rel = os.path.relpath(p, ROOT)
        if fn.endswith(".py"):
            src = open(p, encoding="utf-8", errors="replace").read()
            try:
                ast.parse(src)
            except SyntaxError as e:
                syntax_bad.append((rel, str(e)))
        if fn.endswith((".py", ".sql", ".md", ".txt")):
            txt = open(p, encoding="utf-8", errors="replace").read()
            for pat, label in PRIV_PATTERNS:
                for m in pat.finditer(txt):
                    line = txt[:m.start()].count("\n") + 1
                    privacy_hits.append((rel, line, label, m.group(0)[:40]))

print("py files checked, syntax errors:", len(syntax_bad))
for r, e in syntax_bad:
    print("  !!", r, e[:100])
print("privacy scan hits:", len(privacy_hits))
for r, ln, label, frag in privacy_hits[:30]:
    print("  !! %-55s L%-5d %-22s %s" % (r, ln, label, frag))
