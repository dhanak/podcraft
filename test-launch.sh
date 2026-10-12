#!/usr/bin/env bash
# Offline checks for revision caching, tags, containment, and arguments.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test_path=$PATH
task_tmp=$(mktemp -d)
trap 'rm -rf -- "$task_tmp"' EXIT
mkdir "$task_tmp/bin"
export REAL_GIT
REAL_GIT=$(command -v git)
cat > "$task_tmp/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -eu
if [[ $1 == check-ref-format ]]; then exec "$REAL_GIT" "$@"; fi
[[ $1 == ls-remote ]]
[[ ${GIT_STATUS:-0} == 0 ]] || exit 42
printf '%s\trefs/heads/main\n' "$MOCK_MAIN_SHA"
printf '%s\trefs/heads/feature/foo\n' "$MOCK_BRANCH_SHA"
printf '%s\trefs/tags/v1\n' "$MOCK_BRANCH_SHA"
printf '%s\trefs/tags/v1^{}\n' "$MOCK_TAG_SHA"
MOCK
cat > "$task_tmp/bin/podman" <<'MOCK'
#!/usr/bin/env bash
set -eu
engine=${0##*/}
if [[ $1 == info ]]; then
    if [[ $engine == podman ]]; then exit "${PODMAN_STATUS:-0}"; fi
    exit "${DOCKER_STATUS:-0}"
fi
printf '%s\n' "$engine" "$@" >> "$ENGINE_LOG"
if [[ $1 == image && $2 == inspect ]]; then exit "${IMAGE_STATUS:-1}"; fi
if [[ $1 == build ]]; then
    if [[ ${CHECK_MODES:-0} == 1 ]]; then
        context=${!#}
        [[ -z $(find "$context/dist" -type f ! -perm -004) ]]
        [[ -z $(find "$context/dist" -type d ! -perm -005) ]]
    fi
    exit "${BUILD_STATUS:-0}"
fi
if [[ $1 == run ]]; then
    printf 'container-run\n' >> "$ENGINE_LOG"
    printf '%064d\n' 0
fi
MOCK
cat > "$task_tmp/bin/uv" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' uv "$@" >> "$ENGINE_LOG"
if [[ ${3##*/} == release.py ]]; then
    if [[ $4 == resolve || $4 == select ]]; then
        [[ ${RELEASE_STATUS:-3} == 0 ]] || exit "${RELEASE_STATUS:-3}"
        tag=${MOCK_RELEASE_TAG:-v1}
        printf '%s\t%s\t%s\n' "$tag" \
            "https://github.com/storytold/$5/releases/$tag.zip" '-'
    else
        printf '%s\n' "$7" > "$UNPACK_DIR_LOG"
        [[ ${UNPACK_STATUS:-0} == 0 ]] || exit "$UNPACK_STATUS"
        mkdir -p "$7"
        printf '<html>test</html>\n' > "$7/index.html"
        printf 'dist\n'
    fi
    exit 0
fi
if [[ ${RELAY_INTERRUPT:-0} == 1 ]]; then kill -INT "$PPID"; fi
exit "${RELAY_STATUS:-0}"
MOCK
chmod +x "$task_tmp/bin/podman" "$task_tmp/bin/git" "$task_tmp/bin/uv"
cp "$task_tmp/bin/podman" "$task_tmp/bin/docker"
export PATH="$task_tmp/bin:$PATH" ENGINE_LOG="$task_tmp/engine.log"
export MOCK_MAIN_SHA=1111111111111111111111111111111111111111
export MOCK_BRANCH_SHA=2222222222222222222222222222222222222222
export MOCK_TAG_SHA=3333333333333333333333333333333333333333
unset CONTAINER_ENGINE REPO_URL GIT_REF WEB_DIR PORT BIND_ADDRESS IMAGE
unset PODMAN_STATUS DOCKER_STATUS BUILD_STATUS GIT_STATUS RELAY_STATUS
unset RELAY_INTERRUPT IMAGE_STATUS
unset RELEASE_STATUS UNPACK_STATUS MOCK_RELEASE_TAG CHECK_MODES
export UNPACK_DIR_LOG="$task_tmp/unpack-dir"
export GIT_REF=main

assert_line() {
    local expected=$1 line
    while IFS= read -r line; do
        if [[ $line == "$expected" ]]; then return 0; fi
    done < "$ENGINE_LOG"
    printf 'Missing argument: %s\n' "$expected" >&2
    exit 1
}

cd "$task_tmp"
bash "$script_dir/launch.sh" > "$task_tmp/output"
assert_line podman
assert_line REPO_URL=https://github.com/storytold/wordcraft.git
assert_line "GIT_REF=$MOCK_MAIN_SHA"
assert_line localhost/storytold-wordcraft:latest
assert_line WEB_DIR=apps/wordcraft-web
assert_line "$script_dir/Containerfile"
assert_line "$script_dir/relay.py"
assert_line 8080
for flag in --network=none --read-only --user=101:101 --cap-drop=ALL \
    --security-opt=no-new-privileges --pids-limit=64 --memory=256m --cpus=1; do
    assert_line "$flag"
done
assert_line /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777

# Default resolves a release and packages static files, never resolving Git.
unset GIT_REF
: > "$ENGINE_LOG"
RELEASE_STATUS=0 GIT_STATUS=42 bash "$script_dir/launch.sh" \
    > "$task_tmp/output"
assert_line release
assert_line localhost/storytold-wordcraft:v1
assert_line WEB_DIR=dist
unpack_dir=$(cat "$UNPACK_DIR_LOG")
[[ ! -e ${unpack_dir%/dist} ]]

# Private host permissions must not make files unreadable by container UID 101.
for mask in 027 077; do
    (
        umask "$mask"
        RELEASE_STATUS=0 CHECK_MODES=1 bash "$script_dir/launch.sh" \
            > "$task_tmp/output"
    )
done

: > "$ENGINE_LOG"
RELEASE_STATUS=0 IMAGE_STATUS=0 BUILD_STATUS=42 UNPACK_STATUS=42 \
    bash "$script_dir/launch.sh" > "$task_tmp/output"
assert_line container-run
while IFS= read -r line; do
    [[ $line != build ]] || { printf 'Rebuilt release image\n' >&2; exit 1; }
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
RELEASE_STATUS=0 IMAGE_STATUS=0 bash "$script_dir/launch.sh" --build \
    > "$task_tmp/output"
assert_line build
assert_line release

: > "$ENGINE_LOG"
RELEASE_STATUS=0 MOCK_RELEASE_TAG=v2 bash "$script_dir/launch.sh" \
    > "$task_tmp/output"
assert_line localhost/storytold-wordcraft:v2

: > "$ENGINE_LOG"
RELEASE_STATUS=0 GIT_REF=v1 bash "$script_dir/launch.sh" > "$task_tmp/output"
assert_line release
assert_line localhost/storytold-wordcraft:v1

for version in 0.5.10 0.5 0; do
    : > "$ENGINE_LOG"
    RELEASE_STATUS=0 MOCK_RELEASE_TAG=v0.5.10 GIT_REF=main GIT_STATUS=42 \
        bash "$script_dir/launch.sh" "wordcraft@$version" --detach \
        > "$task_tmp/output"
    assert_line select
    assert_line "$version"
    assert_line wordcraft
    assert_line localhost/storytold-wordcraft:v0.5.10
    assert_line WEB_DIR=dist
done

: > "$ENGINE_LOG"
RELEASE_STATUS=0 MOCK_RELEASE_TAG=v0.5.10 GIT_REF='' IMAGE_STATUS=0 \
    BUILD_STATUS=42 UNPACK_STATUS=42 \
    bash "$script_dir/launch.sh" wordcraft@0.5 > "$task_tmp/output"
assert_line select
assert_line container-run
while IFS= read -r line; do
    [[ $line != build ]] \
        || { printf 'Rebuilt cached version selection\n' >&2; exit 1; }
done < "$ENGINE_LOG"

for status in 1 3; do
    : > "$ENGINE_LOG"
    if RELEASE_STATUS=$status bash "$script_dir/launch.sh" wordcraft@0.5 \
        > "$task_tmp/output" 2>&1; then
        printf 'Ignored version selection failure\n' >&2
        exit 1
    fi
    while IFS= read -r line; do
        [[ $line != build && $line != container-run ]] \
            || { printf 'Ran missing version\n' >&2; exit 1; }
    done < "$ENGINE_LOG"
done

for setting in RELEASE_STATUS=1 RELEASE_STATUS=3 UNPACK_STATUS=42 \
    BUILD_STATUS=42; do
    : > "$ENGINE_LOG"
    if RELEASE_STATUS=0 env "$setting" bash "$script_dir/launch.sh" \
        > "$task_tmp/output" 2>&1; then
        printf 'Ignored release failure: %s\n' "$setting" >&2
        exit 1
    fi
    unpack_dir=$(cat "$UNPACK_DIR_LOG")
    [[ ! -e ${unpack_dir%/dist} ]]
    while IFS= read -r line; do
        [[ $line != container-run ]] \
            || { printf 'Ran failed release\n' >&2; exit 1; }
    done < "$ENGINE_LOG"
done
export GIT_REF=main

: > "$ENGINE_LOG"
IMAGE_STATUS=0 BUILD_STATUS=42 bash "$script_dir/launch.sh" \
    > "$task_tmp/output"
assert_line container-run
while IFS= read -r line; do
    [[ $line != build ]] || { printf 'Rebuilt cached image\n' >&2; exit 1; }
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
IMAGE_STATUS=0 bash "$script_dir/launch.sh" --build > "$task_tmp/output"
assert_line build
assert_line "GIT_REF=$MOCK_MAIN_SHA"
assert_line localhost/storytold-wordcraft:latest

: > "$ENGINE_LOG"
IMAGE_STATUS=0 GIT_REF=v1 bash "$script_dir/launch.sh" wordcraft --build \
    > "$task_tmp/output"
assert_line build
assert_line "GIT_REF=$MOCK_TAG_SHA"
assert_line localhost/storytold-wordcraft:v1

: > "$ENGINE_LOG"
MOCK_MAIN_SHA=$MOCK_BRANCH_SHA bash "$script_dir/launch.sh" \
    > "$task_tmp/output"
assert_line "GIT_REF=$MOCK_BRANCH_SHA"
assert_line localhost/storytold-wordcraft:latest

: > "$ENGINE_LOG"
PODMAN_STATUS=1 bash "$script_dir/launch.sh" gridcraft \
    --detach --label 'description=two words' > "$task_tmp/output"
assert_line docker
assert_line REPO_URL=https://github.com/storytold/gridcraft.git
assert_line --detach
assert_line '--label=description=two words'

: > "$ENGINE_LOG"
bash "$script_dir/launch.sh" --debug --name debug > "$task_tmp/output"
assert_line --debug
assert_line --name=debug
while IFS= read -r line; do
    [[ $line != --rm ]] \
        || { printf 'Debug container removed automatically\n' >&2; exit 1; }
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
CONTAINER_ENGINE=docker GIT_REF=v1 PORT=09000 WEB_DIR='custom web' \
    REPO_URL=https://example.com/app.git IMAGE=localhost/custom \
    bash "$script_dir/launch.sh" wordcraft --name custom \
    > "$task_tmp/output"
assert_line docker
assert_line "GIT_REF=$MOCK_TAG_SHA"
assert_line 'WEB_DIR=custom web'
assert_line REPO_URL=https://example.com/app.git
assert_line localhost/custom:v1
assert_line --name=custom
assert_line 9000

: > "$ENGINE_LOG"
MOCK_TAG_SHA=$MOCK_MAIN_SHA GIT_REF=v1 bash "$script_dir/launch.sh" \
    > "$task_tmp/output"
assert_line localhost/storytold-wordcraft:v1

: > "$ENGINE_LOG"
GIT_REF=feature/foo bash "$script_dir/launch.sh" > "$task_tmp/output"
assert_line "GIT_REF=$MOCK_BRANCH_SHA"
assert_line localhost/storytold-wordcraft:feature-foo

for sha in "$MOCK_MAIN_SHA" "$MOCK_TAG_SHA"; do
    : > "$ENGINE_LOG"
    GIT_REF=$sha bash "$script_dir/launch.sh" > "$task_tmp/output"
    assert_line "GIT_REF=$sha"
    if [[ $sha == "$MOCK_MAIN_SHA" ]]; then
        assert_line localhost/storytold-wordcraft:latest
    else
        assert_line "localhost/storytold-wordcraft:$sha"
    fi
done

for app in '' '--unknown' 'bad/name' 'bad name' 'wordcraft@' '@0.5' \
    'wordcraft@v0.5' 'wordcraft@0.5.0.1' 'wordcraft@0..5' 'wordcraft@-1' \
    'wordcraft@0.5@1' 'wordcraft@ 0.5' 'wordcraft@0.5.' 'wordcraft@../main'; do
    if bash "$script_dir/launch.sh" "$app" > "$task_tmp/output" 2>&1; then
        printf 'Accepted invalid app: %s\n' "$app" >&2
        exit 1
    fi
done
if bash "$script_dir/launch.sh" wordcraft@0.5 '' \
    > "$task_tmp/output" 2>&1; then
    printf 'Accepted empty argument after APP@VERSION\n' >&2
    exit 1
fi
for setting in PORT= PORT=0 PORT=65536 PORT=abc BIND_ADDRESS= REPO_URL= \
    REPO_URL=http://example.com GIT_REF= GIT_REF=--all GIT_REF=missing \
    WEB_DIR= WEB_DIR=/tmp WEB_DIR=apps/../web IMAGE= IMAGE=custom:latest \
    CONTAINER_ENGINE=other GIT_STATUS=1; do
    if env "$setting" bash "$script_dir/launch.sh" \
        > "$task_tmp/output" 2>&1; then
        printf 'Accepted invalid setting: %s\n' "$setting" >&2
        exit 1
    fi
done
for flag in --privileged --network=host --publish=8080:8080 \
    --security-opt=seccomp=unconfined --volume=/tmp:/data --name= --label= \
    --build= --debug=; do
    if bash "$script_dir/launch.sh" wordcraft "$flag" \
        > "$task_tmp/output" 2>&1; then
        printf 'Accepted unsafe/empty option: %s\n' "$flag" >&2
        exit 1
    fi
done
if bash "$script_dir/launch.sh" --build '' > "$task_tmp/output" 2>&1; then
    printf 'Accepted empty argument after --build\n' >&2
    exit 1
fi
if bash "$script_dir/launch.sh" --debug '' > "$task_tmp/output" 2>&1; then
    printf 'Accepted empty argument after --debug\n' >&2
    exit 1
fi
for flag in --name --label; do
    if bash "$script_dir/launch.sh" wordcraft "$flag" '' \
        > "$task_tmp/output" 2>&1; then
        printf 'Accepted empty value: %s\n' "$flag" >&2
        exit 1
    fi
done

: > "$ENGINE_LOG"
if BUILD_STATUS=42 bash "$script_dir/launch.sh" \
    > "$task_tmp/output" 2>&1; then
    printf 'Ignored build failure\n' >&2
    exit 1
fi
while IFS= read -r line; do
    [[ $line != container-run ]] \
        || { printf 'Ran failed build\n' >&2; exit 1; }
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
if IMAGE_STATUS=0 BUILD_STATUS=42 bash "$script_dir/launch.sh" --build \
    > "$task_tmp/output" 2>&1; then
    printf 'Ignored forced build failure\n' >&2
    exit 1
fi
while IFS= read -r line; do
    if [[ $line == container-run ]]; then
        printf 'Ran stale image after failure\n' >&2
        exit 1
    fi
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
if RELAY_STATUS=1 bash "$script_dir/launch.sh" \
    > "$task_tmp/output" 2>&1; then
    printf 'Ignored relay failure\n' >&2
    exit 1
fi
assert_line stop
assert_line rm

: > "$ENGINE_LOG"
if RELAY_STATUS=1 bash "$script_dir/launch.sh" --debug \
    > "$task_tmp/output" 2>&1; then
    printf 'Ignored debug relay failure\n' >&2
    exit 1
fi
assert_line stop
while IFS= read -r line; do
    [[ $line != rm ]] \
        || { printf 'Removed debug container\n' >&2; exit 1; }
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
if RELAY_INTERRUPT=1 bash "$script_dir/launch.sh" \
    > "$task_tmp/output" 2>&1; then
    printf 'Ignored foreground interrupt\n' >&2
    exit 1
fi
assert_line stop

: > "$ENGINE_LOG"
if PODMAN_STATUS=1 DOCKER_STATUS=1 bash "$script_dir/launch.sh" \
    > "$task_tmp/output" 2>&1; then
    printf 'Accepted unavailable engines\n' >&2
    exit 1
fi
[[ ! -s $ENGINE_LOG ]]
bash "$script_dir/launch.sh" --help > "$task_tmp/output"
printf 'Launcher checks passed.\n'

# Real HTTP parsing and streaming; fake engine, no container/network downloads.
PYTHONDONTWRITEBYTECODE=1 PATH=$test_path uv run --no-project - \
    "$script_dir/relay.py" "$script_dir/release.py" <<'CHECK'
import hashlib
import http.client
import importlib.util
import io
import json
import stat
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.parse
import zipfile
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("relay", sys.argv[1])
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
relay.Relay.engine = "podman"
relay.Relay.container = "test-container"
relay.MAX_BODY = 4
responses = [
    b"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n"
    b"X-Check: yes\r\n\r\n3\r\nwas\r\n1\r\nm\r\n0\r\n\r\n",
    b"HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\n",
    b"HTTP/1.0 200 OK\r\nContent-Length: 5\r\n\r\nlarge",
    b"invalid response\r\n\r\n",
]
methods = ["GET", "HEAD", "GET", "GET"]
native_popen = subprocess.Popen


def run_engine(command, **kwargs):
    assert command[:4] == ["podman", "exec", "test-container", "curl"]
    assert command[-2:] == ["--url", "http://127.0.0.1:8080/?sample"]
    assert methods.pop(0) == ("HEAD" if "--head" in command else "GET")
    code = "import sys; sys.stdout.buffer.write(" + repr(responses.pop(0))
    return native_popen([sys.executable, "-c", code + ")"], **kwargs)


server = relay.HTTPServer(("127.0.0.1", 0), relay.Relay)
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
try:
    with patch.object(relay.subprocess, "Popen", side_effect=run_engine):
        for method, status in [
            ("GET", 200), ("HEAD", 200), ("GET", 502), ("GET", 502)
        ]:
            client = http.client.HTTPConnection(
                *server.server_address, timeout=5
            )
            client.request(method, "/?sample")
            response = client.getresponse()
            assert response.status == status
            body = response.read()
            if status == 200:
                assert body == (b"wasm" if method == "GET" else b"")
                assert response.getheader("Transfer-Encoding") is None
            client.close()
    assert not responses and not methods
finally:
    server.shutdown()
    server.server_close()
    worker.join()
print("Relay checks passed.")

# Exercise real foreground shutdown for app exits and engine wait failures.
for wait_code, output, expected, debug in (
    (0, "0", 0, False), (0, "7", 7, False),
    (42, "", 1, False), (0, "invalid", 1, False), (0, "1", 1, True),
):
    def wait_engine(command, **kwargs):
        assert command == ["podman", "wait", "test-container"]
        code = f"import sys; print({output!r}); sys.exit({wait_code})"
        return native_popen([sys.executable, "-c", code], **kwargs)

    argv = ["relay.py", "podman", "test-container", str(server.server_port)]
    if debug:
        argv.append("--debug")
    with (
        patch.object(sys, "argv", argv),
        patch.object(relay.signal, "signal"),
        patch.object(relay.subprocess, "run") as run,
        patch.object(relay.subprocess, "Popen", side_effect=wait_engine),
        patch.object(sys, "stdout", io.StringIO()) as stdout,
        patch.object(sys, "stderr", io.StringIO()) as stderr,
    ):
        assert relay.main() == expected
        commands = [call.args[0][1] for call in run.call_args_list]
        assert commands[0] == "exec"  # Readiness before announcing service.
        assert ("rm" in commands) != debug
        assert ("logs" in commands) == bool(expected)
        assert "Serving http://" in stdout.getvalue()
        assert ("relay: container" in stderr.getvalue()) == bool(expected)

with (
    patch.object(sys, "argv", argv + ["--detach"]),
    patch.object(relay.os, "fork") as fork,
    patch.object(relay.subprocess, "run") as run,
    patch.object(sys, "stdout", io.StringIO()) as stdout,
    patch.object(sys, "stderr", io.StringIO()) as stderr,
):
    run.side_effect = [subprocess.CalledProcessError(1, "curl"), None]
    assert relay.main() == 1
    assert "Serving" not in stdout.getvalue()
    assert "startup failed" in stderr.getvalue()
    assert run.call_args_list[-1].args[0][1] == "logs"
    fork.assert_not_called()
print("Container lifecycle checks passed.")

spec = importlib.util.spec_from_file_location("release", sys.argv[2])
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
asset_url = (
    "https://github.com/storytold/wordcraft/releases/download/v1/"
    "wordcraft-web-1.zip"
)
metadata = {
    "tag_name": "v1",
    "assets": [{"name": "wordcraft-web-1.zip",
                "browser_download_url": asset_url}],
}
with patch.object(release, "fetch", return_value=json.dumps(metadata)):
    for ref in ("latest", "v1"):
        assert release.resolve(
            "wordcraft", "https://github.com/storytold/wordcraft.git", ref
        ) == ("v1", asset_url, "-")


def rejects(callback, error=ValueError):
    try:
        callback()
    except error:
        return
    raise AssertionError("unsafe input was accepted")


def numbered_release(tag, **flags):
    name = f"wordcraft-web-{tag.removeprefix('v')}.zip"
    return {
        "tag_name": tag,
        "assets": [{"name": name, "browser_download_url": (
            "https://github.com/storytold/wordcraft/releases/download/"
            f"{tag}/{name}"
        )}],
        **flags,
    }


versions = [
    numbered_release("v0.5.9"), numbered_release("v0.5.10"),
    numbered_release("v0.6.0"), numbered_release("v1.0.0"),
    numbered_release("v0.5.99", prerelease=True),
    numbered_release("v0.5.100", draft=True),
    numbered_release("v0.5.200-rc.1"), numbered_release("nightly"),
    numbered_release("0.4.2"),
]
pages = {1: versions}


def github_api(url, _limit):
    parsed = urllib.parse.urlsplit(url)
    if parsed.query:
        page = int(urllib.parse.parse_qs(parsed.query)["page"][0])
        return json.dumps(pages.get(page, []))
    tag = urllib.parse.unquote(parsed.path.rsplit("/", 1)[-1])
    for metadata in versions:
        if metadata["tag_name"] == tag:
            return json.dumps(metadata)
    raise urllib.error.HTTPError(url, 404, "missing", {}, None)


repo = "https://github.com/storytold/wordcraft.git"
with patch.object(release, "fetch", side_effect=github_api):
    for version, tag in (
        ("0.5.10", "v0.5.10"), ("0.5", "v0.5.10"),
        ("0", "v0.6.0"), ("1", "v1.0.0"), ("0.4.2", "0.4.2"),
    ):
        result = release.resolve("wordcraft", repo, version, version_spec=True)
        assert result[0] == tag, (version, result)
    for version in ("2", "0.50", "0.5.8", "", "v0.5", "0.5.0.1", "0..5"):
        rejects(lambda: release.resolve(
            "wordcraft", repo, version, version_spec=True
        ))
    pages = {1: [versions[0]] * 100, 2: [versions[1]]}
    assert release.resolve(
        "wordcraft", repo, "0.5", version_spec=True
    )[0] == "v0.5.10"
unavailable = urllib.error.HTTPError(asset_url, 503, "unavailable", {}, None)
with patch.object(release, "fetch", side_effect=unavailable):
    rejects(lambda: release.resolve(
        "wordcraft", repo, "0.5.10", version_spec=True
    ), urllib.error.HTTPError)
with patch.object(release, "fetch", return_value="{}"):
    rejects(lambda: release.resolve(
        "wordcraft", repo, "0.5", version_spec=True
    ))
print("Version selection checks passed.")


metadata["assets"] = []
with patch.object(release, "fetch", return_value=json.dumps(metadata)):
    rejects(lambda: release.resolve(
        "wordcraft", "https://github.com/storytold/wordcraft.git", "latest"
    ))
not_found = urllib.error.HTTPError(asset_url, 404, "missing", {}, None)
with patch.object(release, "fetch", side_effect=not_found):
    rejects(lambda: release.resolve(
        "wordcraft", "https://github.com/storytold/wordcraft.git", "branch"
    ), release.NoReleaseError)
    rejects(lambda: release.resolve(
        "wordcraft", "https://github.com/storytold/wordcraft.git", "latest"
    ), urllib.error.HTTPError)
with patch.object(release.urllib.request, "urlopen",
                  return_value=io.BytesIO(b"1234")):
    rejects(lambda: release.fetch(asset_url, 3))


def bundle(member):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w") as archive:
        archive.writestr(member, b"<html>app</html>")
    return output.getvalue()


with tempfile.TemporaryDirectory() as folder:
    for number, member in enumerate(("index.html", "web-v1/index.html")):
        data = bundle(member)
        digest = "sha256:" + hashlib.sha256(data).hexdigest()
        with patch.object(release, "fetch", return_value=data):
            root = release.unpack(asset_url, digest, Path(folder) / str(number))
            assert (Path(folder) / root / "index.html").read_bytes()
            rejects(lambda: release.unpack(
                asset_url, "sha256:" + "0" * 64, Path(folder) / "bad-digest"
            ))
    link = zipfile.ZipInfo("index.html")
    link.create_system = 3
    link.external_attr = (stat.S_IFLNK | 0o777) << 16
    for number, member in enumerate((
        "../escape", "/escape", "web/../../escape", "C:escape",
        "web\\escape", link, "missing-index.txt"
    )):
        with patch.object(release, "fetch", return_value=bundle(member)):
            rejects(lambda: release.unpack(
                asset_url, "-", Path(folder) / f"unsafe-{number}"
            ))
    with patch.object(release, "fetch", return_value=bundle("index.html")):
        with patch.object(release, "MAX_UNPACKED", 1):
            rejects(lambda: release.unpack(
                asset_url, "-", Path(folder) / "oversized"
            ))
    assert not (Path(folder) / "escape").exists()
print("Release checks passed.")
CHECK
