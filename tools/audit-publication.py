"""Inspect tracked/publishable files without displaying any matched secret values."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
patterns = {
    "private key": r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "GitHub credential": r"\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b",
    "personal home path": r"/Users/[^/\s]+/",
    "campus account": r"\bQSZ\d{6,}\b",
    "SSH host key": r"\bssh-(?:rsa|ed25519) AAAA[A-Za-z0-9+/]{20,}",
    "device MAC": r"(?i)(?<![\w:])(?:[0-9a-f]{2}:){5}[0-9a-f]{2}(?![\w:])",
}
bad = []
try:
    tracked = subprocess.run(["git", "ls-files", "-z"], cwd=root,
                             capture_output=True, check=True).stdout
    files = [root / name.decode() for name in tracked.split(b"\0") if name]
except (subprocess.CalledProcessError, FileNotFoundError):
    files = [p for p in root.rglob("*") if p.is_file() and not any(
        part in {".git", "dist", "__pycache__"} for part in p.relative_to(root).parts)]
for p in files:
    rel = p.relative_to(root)
    if any(part in {"work", "private", "backups", "__pycache__"} for part in rel.parts) or p.name.startswith("known_hosts"):
        bad.append(f"{rel}: forbidden private artifact")
        continue
    if p.suffix in {".log", ".pid", ".pcap", ".pcapng", ".key", ".pem", ".conf", ".zip"}:
        bad.append(f"{rel}: forbidden runtime artifact")
        continue
    try:
        lines = p.read_text().splitlines()
    except UnicodeDecodeError:
        if p.name != "AppIcon.icns":
            bad.append(f"{rel}: unreviewed binary")
        continue
    # The scanner's regex definitions are not actual sensitive data.
    if p.resolve() == Path(__file__).resolve():
        continue
    for n, line in enumerate(lines, 1):
        for label, pattern in patterns.items():
            if re.search(pattern, line):
                bad.append(f"{rel}:{n}: possible {label}")
if bad:
    print("Publication audit failed (values omitted):")
    print("\n".join(bad))
    sys.exit(1)
print(f"PASS: publication audit checked {len(files)} files; no listed private artifacts or credential patterns.")

