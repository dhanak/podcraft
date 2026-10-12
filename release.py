"""Resolve GitHub web releases and unpack bounded, verified ZIP data."""

import argparse
import hashlib
import io
import json
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath

MAX_DOWNLOAD = 128 * 1024 * 1024
MAX_UNPACKED = 512 * 1024 * 1024


class NoReleaseError(Exception):
    pass


def fetch(url, limit):
    if urllib.parse.urlsplit(url).scheme != "https":
        raise ValueError("downloads require HTTPS")
    request = urllib.request.Request(
        url, headers={"User-Agent": "storytold-container-launcher"}
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("download exceeds size limit")
    return data


def select_release(name, version):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", version):
        raise ValueError("version needs 1..3 numeric components, without v")
    parts = tuple(int(part) for part in version.split("."))
    api = f"https://api.github.com/repos/{name}/releases"
    if len(parts) == 3:
        exact = ".".join(str(part) for part in parts)
        for tag in ("v" + exact, exact):
            try:
                release = json.loads(fetch(f"{api}/tags/{tag}", 2 * 1024**2))
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
            else:
                if release["tag_name"] != tag:
                    raise ValueError(
                        "release does not match requested version"
                    )
                return release
        raise ValueError(f"no published release for version {version}")
    best = None
    selected = None
    page = 1
    while True:
        releases = json.loads(
            fetch(f"{api}?per_page=100&page={page}", 2 * 1024**2)
        )
        if not isinstance(releases, list):
            raise ValueError("invalid release list")
        for release in releases:
            if release.get("draft") or release.get("prerelease"):
                continue
            match = re.fullmatch(
                r"v?([0-9]+)\.([0-9]+)\.([0-9]+)", release["tag_name"]
            )
            if not match:
                continue
            candidate = tuple(int(part) for part in match.groups())
            if candidate[: len(parts)] == parts and (
                best is None or candidate > best
            ):
                best, selected = candidate, release
        if len(releases) < 100:
            break
        page += 1
    if selected is None:
        raise ValueError(f"no stable release matches version {version}")
    return selected


def resolve(app, repo, ref, *, version_spec=False):
    parsed = urllib.parse.urlsplit(repo)
    name = parsed.path.strip("/").removesuffix(".git")
    if parsed.netloc != "github.com" or not re.fullmatch(
        r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", name
    ):
        if ref != "latest" and not version_spec:
            raise NoReleaseError("not a GitHub release repository")
        raise ValueError("releases require a GitHub repository")
    if version_spec:
        release = select_release(name, ref)
        ref = release["tag_name"]
    else:
        endpoint = (
            "latest"
            if ref == "latest"
            else "tags/" + urllib.parse.quote(ref, safe="")
        )
        try:
            data = fetch(
                f"https://api.github.com/repos/{name}/releases/{endpoint}",
                2 * 1024 * 1024,
            )
        except urllib.error.HTTPError as error:
            if error.code == 404 and ref != "latest":
                raise NoReleaseError(
                    "no published release for this ref"
                ) from error
            raise
        release = json.loads(data)
    tag = release["tag_name"]
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.+/-]*", tag):
        raise ValueError("invalid release tag")
    if release.get("draft") or (ref == "latest" and release.get("prerelease")):
        raise ValueError("latest must be a published stable release")
    if ref != "latest" and tag != ref:
        raise ValueError("release does not match requested tag")
    asset_name = f"{app}-web-{tag.removeprefix('v')}.zip"
    assets = [a for a in release["assets"] if a["name"] == asset_name]
    if len(assets) != 1:
        raise ValueError(f"release {tag} needs exactly one {asset_name}")
    asset = assets[0]
    url = asset["browser_download_url"]
    parsed = urllib.parse.urlsplit(url)
    expected = f"/{name}/releases/download/{tag}/{asset_name}"
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or urllib.parse.unquote(parsed.path) != expected
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("invalid release asset URL")
    digest = asset.get("digest") or "-"
    if digest != "-" and not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise ValueError("invalid release asset digest")
    return tag, url, digest


def unpack(url, digest, destination):
    data = fetch(url, MAX_DOWNLOAD)
    if (
        digest != "-"
        and "sha256:" + hashlib.sha256(data).hexdigest() != digest
    ):
        raise ValueError("release ZIP SHA-256 mismatch")
    destination = Path(destination)
    destination.mkdir()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        entries = archive.infolist()
        if (
            len(entries) > 4096
            or sum(entry.file_size for entry in entries) > MAX_UNPACKED
        ):
            raise ValueError("release ZIP exceeds extraction limits")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            mode = stat.S_IFMT(entry.external_attr >> 16)
            if (
                path.is_absolute()
                or ".." in path.parts
                or "\\" in entry.filename
                or ":" in entry.filename
                or entry.orig_filename != entry.filename
                or mode not in (0, stat.S_IFREG, stat.S_IFDIR)
                or entry.flag_bits & 1
            ):
                raise ValueError("unsafe release ZIP member")
        archive.extractall(destination)
    roots = (
        [destination]
        if (destination / "index.html").is_file()
        else [
            child
            for child in destination.iterdir()
            if child.is_dir() and (child / "index.html").is_file()
        ]
    )
    if len(roots) != 1 or not (roots[0] / "index.html").stat().st_size:
        raise ValueError("release ZIP needs one web root with index.html")
    return str(roots[0].relative_to(destination.parent))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("resolve", "select", "unpack"))
    parser.add_argument("values", nargs=3)
    args = parser.parse_args()
    try:
        if args.action == "unpack":
            print(unpack(*args.values))
        else:
            print(
                "\t".join(
                    resolve(*args.values, version_spec=args.action == "select")
                )
            )
    except NoReleaseError:
        return 3  # Only absent releases permit an explicit source fallback.
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        zipfile.BadZipFile,
    ) as error:
        parser.exit(1, f"release: {error}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
