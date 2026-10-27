#!/usr/bin/env python3
"""Sign complete Vortex release assets with the separately stored owner key.

Requires Python cryptography in the release environment. Never place the key in
the repository, asset directory, web root, or frontend. Signing covers exact JSON
bytes; clients verify the signature and then the selected package's SHA-256.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

EXPECTED_PUBLIC_KEY = "ea244ad764bc6556b93c5ca9a8e5075efc20dde9ac23ce26800be72bb2ece6e9"


def atomic_write(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".release-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key", type=Path, required=True)
    parser.add_argument("--assets", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--platforms", choices=("all", "windows-linux"), default="all",
                        help="Sign only existing Windows and Linux packages when Mac notarization is pending")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", args.version):
        parser.error("version must be a numeric dotted release")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("commit must be the exact tested source SHA")
    key_path = args.key.resolve(strict=True)
    assets = args.assets.resolve(strict=True)
    repository = Path(__file__).resolve().parents[1]
    if assets == key_path.parent or assets in key_path.parents or repository in key_path.parents or ".git" in key_path.parts:
        parser.error("signing key must be outside the assets and repository")
    if key_path.stat().st_mode & 0o077:
        parser.error("signing key must be readable only by its owner (0600)")
    key = serialization.load_pem_private_key(key_path.read_bytes(), password=None)
    if not isinstance(key, Ed25519PrivateKey):
        parser.error("an Ed25519 private key is required")
    public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    if public != EXPECTED_PUBLIC_KEY:
        parser.error("key does not match the public key pinned in this release")
    names = ["Red-XAI-Vortex-linux-amd64.tar.gz", "Red-XAI-Vortex-windows-amd64.zip"]
    if args.platforms == "all":
        names.extend([f"Vortex-{args.version}-mac.zip", f"Vortex-{args.version}-mac.dmg"])
    hashes = {}
    for name in names:
        path = assets / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            parser.error(f"missing regular release asset: {name}")
        with path.open("rb") as incoming:
            hashes[name] = hashlib.file_digest(incoming, "sha256").hexdigest()
    manifest = json.dumps({"version": args.version, "sourceCommit": args.commit, "assets": hashes},
                          sort_keys=True, separators=(",", ":")).encode() + b"\n"
    signature = key.sign(manifest)
    key.public_key().verify(signature, manifest)
    atomic_write(assets / "release-manifest.json", manifest)
    atomic_write(assets / "release-manifest.sig", signature.hex().encode() + b"\n")
    atomic_write(assets / "SHA256SUMS", "".join(f"{hashes[name]}  {name}\n" for name in names).encode())
    print(f"Signed {len(hashes)} assets for {args.version} at {args.commit}; public key {public}")


if __name__ == "__main__":
    main()
