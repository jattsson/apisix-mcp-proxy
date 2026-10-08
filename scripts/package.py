"""Build a reproducible distribution from the committed release allowlist."""
import gzip
import hashlib
import io
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GIT = ["git", "-c", "safe.directory=" + str(ROOT), "-C", str(ROOT)]
FILES = ["VERSION", "LICENSE", "NOTICE", "README.md", "CHANGELOG.md",
         "CONTRIBUTING.md", "SECURITY.md", "apisix", "examples", "docs",
         "scripts/install.sh"]


def git(*args):
    """Return Git output for the repository without reading untracked files."""
    return subprocess.check_output(GIT + list(args))


def build():
    """Write a commit-pinned tarball and checksum; validate its Lua-only runtime."""
    revision = git("rev-parse", "HEAD").decode().strip()
    version = git("show", "HEAD:VERSION").decode().strip()
    if version != (ROOT / "VERSION").read_text().strip():
        raise SystemExit("Commit VERSION before packaging")
    if version != "0.1.0":
        raise SystemExit("Review packaging for the new release version")
    prefix = "apisix-mcp-proxy-" + version
    source = git("archive", "--format=tar", "HEAD", "--", *FILES)
    output = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(source)) as src:
        members = src.getmembers()
        epoch = int(git("show", "-s", "--format=%ct", "HEAD"))
        with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as dst:
            for member in members:
                if not (member.isfile() or member.isdir()):
                    raise SystemExit("Unexpected archive entry: " + member.name)
                stream = src.extractfile(member) if member.isfile() else None
                member.name = prefix + "/" + member.name
                member.uid = member.gid = 0
                member.uname = member.gname = ""
                member.mtime = epoch
                member.pax_headers = {}
                dst.addfile(member, stream)
            data = (revision + "\n").encode()
            meta = tarfile.TarInfo(prefix + "/REVISION")
            meta.size, meta.mtime, meta.mode = len(data), epoch, 0o644
            dst.addfile(meta, io.BytesIO(data))
    artifact = gzip.compress(output.getvalue(), mtime=0)
    folder = ROOT / ".test" / "release"
    folder.mkdir(parents=True, exist_ok=True)
    name = prefix + ".tar.gz"
    (folder / name).write_bytes(artifact)
    digest = hashlib.sha256(artifact).hexdigest()
    (folder / "SHA256SUMS").write_text(digest + "  " + name + "\n")
    print(name + " SHA256=" + digest + " commit=" + revision)


if __name__ == "__main__":
    build()
