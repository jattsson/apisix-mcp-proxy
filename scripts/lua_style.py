"""Format Lua with pinned StyLua plus APISIX spacing, and check function contracts."""
import argparse
import difflib
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STYLUA_VERSION = "2.5.2"


def lua_files():
    """Limit checks to owned Lua source, including test fixtures and helpers."""
    return sorted((ROOT / "apisix").rglob("*.lua")) + sorted(
        (ROOT / "fixtures").glob("*.lua")
    ) + sorted((ROOT / "tests").rglob("*.lua"))


def apisix_spacing(source):
    """Keep two blank lines before documented functions and gaps before branches."""
    lines = []
    for line in source.splitlines():
        if line.lstrip().startswith("--- ") and lines:
            while lines and not lines[-1].strip():
                lines.pop()
            lines.extend(["", ""])
        elif re.match(r"^\s*(?:elseif\b|else$)", line):
            if lines and lines[-1].strip():
                lines.append("")
        lines.append(line)
    return "\n".join(lines) + "\n"


def contract_errors(source):
    """Check complete adjacent LDoc blocks for named functions and reject lambdas."""
    errors = []
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if len(line) > 100:
            errors.append(f"{index + 1}: line exceeds 100 characters")
        match = re.match(r"^\s*(?:local )?function ([\w.]+)\(([^)]*)\)", line)
        if not match:
            if re.search(r"\bfunction\s*\(", line) and not line.lstrip().startswith("--"):
                errors.append(f"{index + 1}: name and document this callback")
            continue
        name, signature = match.groups()
        if not re.fullmatch(r"(?:[a-z][a-z0-9_]*\.)?[a-z][a-z0-9_]*", name):
            errors.append(f"{index + 1}: function name must use snake_case")
        start = index - 1
        while start >= 0 and lines[start].lstrip().startswith("--"):
            start -= 1
        block = "\n".join(lines[start + 1:index])
        if not block.lstrip().startswith("--- ") or "-- @return " not in block:
            errors.append(f"{index + 1}: missing function summary or return contract")
        expected = [name.strip() for name in signature.split(",") if name.strip()]
        documented = re.findall(r"-- @param (\w+) \S+ .+", block)
        if expected != documented:
            errors.append(f"{index + 1}: parameter documentation differs from signature")
    return errors


def main():
    """Check by default; --write applies formatting but never suppresses lint failures."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--stylua", default="stylua")
    args = parser.parse_args()
    version = subprocess.check_output([args.stylua, "--version"], text=True).strip()
    if version != f"stylua {STYLUA_VERSION}":
        raise SystemExit(f"Expected StyLua {STYLUA_VERSION}, received {version}")
    failed = False
    files = lua_files()
    for path in files:
        original = path.read_text(encoding="utf-8")
        formatted = subprocess.check_output(
            [args.stylua, "--config-path", str(ROOT / ".stylua.toml"), "--verify", "-"],
            input=original, text=True, encoding="utf-8",
        )
        formatted = apisix_spacing(formatted)
        if original != formatted:
            if args.write:
                path.write_text(formatted, encoding="utf-8", newline="\n")
            else:
                failed = True
                print("".join(difflib.unified_diff(
                    original.splitlines(True), formatted.splitlines(True),
                    fromfile=str(path.relative_to(ROOT)), tofile="required formatting",
                )), end="")
        for error in contract_errors(formatted):
            failed = True
            print(f"{path.relative_to(ROOT)}:{error}")
    if failed:
        raise SystemExit(1)
    print(f"Formatting and function documentation passed for {len(files)} Lua files.")


if __name__ == "__main__":
    main()
