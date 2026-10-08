# Releases

VERSION defines the distribution version. APISIX's numeric plugin version is
separate metadata; the MCP upstream client identifies itself as 0.1.0.

Build a committed revision with Python 3 and Git:

    python3 scripts/package.py

The command creates .test/release/apisix-mcp-proxy-0.1.0.tar.gz and SHA256SUMS.
It reads only the committed allowlist, rejects a mismatched VERSION, records the
full commit in REVISION and creates deterministic archive bytes. It excludes Git
history, fixtures, tests, generated certificates and local configuration.

Verify the download with sha256sum -c SHA256SUMS, extract it, and run
bash scripts/install.sh /opt/mcp-proxy from the extracted directory. Follow the
README for APISIX configuration and rollout; extracting is not activation.

Before publishing, require successful CI on the exact release commit, inspect
archive contents and test installation into an empty directory. Create a draft
GitHub release named v0.1.0 targeting that commit, attach the archive and checksum,
and use CHANGELOG.md for release notes. Publishing a release and making the
repository public are separate operations. Review all public refs and their
history before changing visibility; a clean current tree does not clean history.

Tag only the final reviewed release commit. Never move a published release tag;
use a new patch version for corrections. Runtime dependencies are supplied by the
supported APISIX distribution rather than bundled in the release archive.
