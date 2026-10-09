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
if [[ $1 == build ]]; then exit "${BUILD_STATUS:-0}"; fi
if [[ $1 == run ]]; then
    printf '%064d\n' 0
fi
MOCK
cat > "$task_tmp/bin/uv" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf '%s\n' uv "$@" >> "$ENGINE_LOG"
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

: > "$ENGINE_LOG"
IMAGE_STATUS=0 BUILD_STATUS=42 bash "$script_dir/launch.sh" \
    > "$task_tmp/output"
assert_line run
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

for app in '' '--unknown' 'bad/name' 'bad name'; do
    if bash "$script_dir/launch.sh" "$app" > "$task_tmp/output" 2>&1; then
        printf 'Accepted invalid app: %s\n' "$app" >&2
        exit 1
    fi
done
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
    --build=; do
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
    [[ $line != run ]] || { printf 'Ran failed build\n' >&2; exit 1; }
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
if IMAGE_STATUS=0 BUILD_STATUS=42 bash "$script_dir/launch.sh" --build \
    > "$task_tmp/output" 2>&1; then
    printf 'Ignored forced build failure\n' >&2
    exit 1
fi
while IFS= read -r line; do
    [[ $line != run ]] || { printf 'Ran stale image after failure\n' >&2
        exit 1; }
done < "$ENGINE_LOG"

: > "$ENGINE_LOG"
if RELAY_STATUS=1 bash "$script_dir/launch.sh" \
    > "$task_tmp/output" 2>&1; then
    printf 'Ignored relay failure\n' >&2
    exit 1
fi
assert_line stop

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
PATH=$test_path uv run --no-project - "$script_dir/relay.py" <<'CHECK'
import http.client
import importlib.util
import subprocess
import sys
import threading
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
CHECK
