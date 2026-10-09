from pathlib import Path
import subprocess
import sys


root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1]).resolve()
prefix = "code/adapters/ramp/ronna/"


def git(*args):
    return subprocess.check_output(["git", "-C", str(source), *args])


revision = git("rev-parse", "HEAD").decode().strip()
files = git("ls-tree", "-r", "--name-only", "HEAD", "--", prefix).decode().splitlines()
if not files or any(not name.endswith(".lua") for name in files):
    raise SystemExit("Expected a tracked Lua adapter at " + prefix)
if git("status", "--porcelain", "--", prefix).strip():
    raise SystemExit("Commit the adapter changes in Ronna before synchronizing")

contents = {name[len(prefix):]: git("show", "HEAD:" + name) for name in files}
for directory in ("lua", "plugin"):
    for path in (root / directory).rglob("*.lua"):
        if path.relative_to(root).as_posix() not in contents:
            path.unlink()
for name, content in contents.items():
    destination = root / name
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(content)
(root / "upstream.txt").write_text(revision + "\n")
print("Synchronized Ronna Lua adapter from " + revision)
