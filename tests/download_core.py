"""Download an official Linux Xray release and verify its published SHA-256.

Usage: python3 tests/download_core.py --version v26.10.21 --output /tmp/xray-core
Honors the normal HTTPS proxy and system CA configuration. No software is installed.
"""

import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import tempfile
import time
import urllib.error
import urllib.request
import zipfile


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": "Xray-script-tests"})
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=90) as response, destination.open("wb") as out:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    if total > 128 * 1024 * 1024:
                        raise ValueError("Release asset exceeds 128 MiB")
                    out.write(chunk)
            return
        except urllib.error.HTTPError as error:
            if attempt == 2 or (error.code != 429 and error.code < 500):
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == 2:
                raise
        time.sleep(2 ** attempt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="v26.10.21")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9]+)*", args.version):
        parser.error("--version must be an explicit Xray release tag")
    architecture = {"x86_64": "64", "aarch64": "arm64-v8a"}.get(platform.machine())
    if platform.system() != "Linux" or architecture is None:
        parser.error("This helper supports Linux amd64 and arm64")
    args.output.mkdir(parents=True, exist_ok=True)
    archive_name = f"Xray-linux-{architecture}.zip"
    url = f"https://github.com/XTLS/Xray-core/releases/download/{args.version}/{archive_name}"
    with tempfile.TemporaryDirectory(prefix=".download-", dir=args.output) as temporary:
        work = Path(temporary)
        archive, digest = work / archive_name, work / (archive_name + ".dgst")
        download(url, archive)
        download(url + ".dgst", digest)
        matches = re.findall(r"^SHA(?:2-)?256=\s*([0-9a-fA-F]{64})\s*$", digest.read_text(), re.M)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if len(matches) != 1 or actual != matches[0].lower():
            raise SystemExit("Official archive SHA-256 verification failed")
        # Extract only the three expected assets, never paths supplied by a ZIP.
        with zipfile.ZipFile(archive) as zipped:
            for name in ("xray", "geoip.dat", "geosite.dat"):
                (work / name).write_bytes(zipped.read(name))
        (work / "xray").chmod(0o755)
        for path in work.iterdir():
            os.replace(path, args.output / path.name)
        print(f"Verified {args.version} {archive_name}: SHA256 {actual}")


if __name__ == "__main__":
    main()
