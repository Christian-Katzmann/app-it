#!/usr/bin/env python3
"""Build the skills-only App It ZIP with plugin.json at its root."""
import argparse
import hashlib
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path, help="ZIP path outside plugins/app-it")
args = parser.parse_args()
source = Path(__file__).resolve().parents[1] / "plugins/app-it"
output = args.output.expanduser().resolve()
if source == output or source in output.parents:
    parser.error("output must be outside the plugin source")
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(source.rglob("*")):
        rel = file.relative_to(source)
        if any(part in {"coverage", "__pycache__", ".DS_Store"} for part in rel.parts):
            continue
        if file.is_symlink():
            raise ValueError(f"package symlink is not allowed: {rel}")
        if file.is_file():
            entry = zipfile.ZipInfo(rel.as_posix(), date_time=(2026, 9, 30, 0, 0, 0))
            entry.create_system = 3
            executable = bool(file.stat().st_mode & 0o111)
            entry.external_attr = (0o100755 if executable else 0o100644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, file.read_bytes())
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert "plugin.json" in archive.namelist()
    assert "skills/app-it/SKILL.md" in archive.namelist()
digest = hashlib.sha256(output.read_bytes()).hexdigest()
output.with_suffix(output.suffix + ".sha256").write_text(f"{digest}  {output.name}\n")
print(f"{output}\nSHA-256 {digest}")
