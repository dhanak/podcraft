#!/usr/bin/env bash
set -euo pipefail

die() {
    printf 'launch: %s\n' "$*" >&2
    exit 1
}

if [[ ${1-} == --help || ${1-} == -h ]]; then
    cat <<'HELP'
Usage: ./launch.sh [APP[@VERSION]] [--build] [--detach] [--debug]
                   [--name NAME] [--label KEY=VALUE]

Serve a Storytold Trunk/WebAssembly app. Default: wordcraft.
Default: deploy latest published release ZIP; no Rust compilation.
Reuse its local image; build only if missing or --build is passed.
Runtime has no external network. Host relay serves HTTP on localhost.
--debug keeps the stopped container for logs and inspection.
Only build/detach/debug/name/label options are accepted.
APP@VERSION overrides GIT_REF. Omit v: wordcraft@0.5.0, @0.5, or @0.
Partial versions select the highest matching stable release.

Environment:
  CONTAINER_ENGINE  podman or docker; auto-detect working engine by default
  REPO_URL          default: https://github.com/storytold/APP.git
  GIT_REF           release tag, branch, or full commit; default: latest
  WEB_DIR           relative web directory; default: apps/APP-web
  PORT              host relay port, 1..65535; default: 8080
  IMAGE             image repository; default: localhost/storytold-APP

Releases use their version tag. Explicit branches/commits build from source.
main/current-main commit uses :latest; other refs get their own image tag.
HELP
    exit 0
fi

app=wordcraft
version=''
if (( $# )) && [[ $1 != -* ]]; then app=$1; shift; fi
if [[ $app == *@* ]]; then
    version=${app#*@}
    app=${app%%@*}
    [[ $version =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] \
        || die 'APP@VERSION needs 1..3 numeric components, without v'
fi
[[ $app =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die 'invalid app name'
# Whitelist prevents run options from undoing containment.
run_options=()
detached=false
build=false
debug=false
while (( $# )); do
    case $1 in
        --build) build=true; shift ;;
        --detach|-d) detached=true; shift ;;
        --debug) debug=true; shift ;;
        --name|--label)
            if (( $# < 2 )) || [[ -z $2 || $2 == -* ]]; then
                die "$1 needs a nonempty value"
            fi
            run_options+=("$1=$2"); shift 2 ;;
        --name=*|--label=*)
            [[ -n ${1#*=} ]] || die "$1 needs a nonempty value"
            run_options+=("$1"); shift ;;
        *) die "unsupported run option: $1" ;;
    esac
done
repo=${REPO_URL-https://github.com/storytold/$app.git}
ref=${version:-${GIT_REF-latest}}
web_dir=${WEB_DIR-apps/$app-web}
image_repo=${IMAGE-localhost/storytold-$app}
port=${PORT-8080}
[[ $repo == https://* && $repo != https:// ]] || die 'REPO_URL needs HTTPS'
[[ -n $ref && $ref != -* ]] || die 'GIT_REF must be nonempty'
[[ -n $web_dir && $web_dir != /* ]] || die 'WEB_DIR must be relative'
case /$web_dir/ in */../*) die 'WEB_DIR cannot contain ..' ;; esac
[[ ${BIND_ADDRESS-127.0.0.1} == 127.0.0.1 ]] \
    || die 'host relay binds localhost only'
[[ $port =~ ^[0-9]{1,5}$ ]] || die 'PORT must be 1..65535'
port=$((10#$port))
(( port >= 1 && port <= 65535 )) || die 'PORT must be 1..65535'
[[ -n $image_repo && $image_repo != -* ]] || die 'invalid IMAGE'
[[ ${image_repo##*/} != *:* ]] || die 'IMAGE must omit its tag'
command -v uv >/dev/null || die 'uv is required for the host HTTP relay'

engine=${CONTAINER_ENGINE-}
if [[ -n $engine ]]; then
    case $engine in podman|docker) ;; *) die 'invalid CONTAINER_ENGINE' ;; esac
    command -v "$engine" >/dev/null || die "$engine unavailable"
    "$engine" info >/dev/null 2>&1 || die "$engine is not ready"
else
    for candidate in podman docker; do
        if command -v "$candidate" >/dev/null 2>&1 \
            && "$candidate" info >/dev/null 2>&1; then
            engine=$candidate
            break
        fi
    done
    [[ -n $engine ]] || die 'start Podman or Docker, then retry'
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mode=source
release_status=3
release_action=resolve
if [[ -n $version ]]; then release_action=select; fi
if [[ -n $version ]] || [[ $ref != main && ! $ref =~ ^[0-9a-f]{40}$ ]]; then
    release_status=0
    release=$(uv run --no-project "$script_dir/release.py" \
        "$release_action" "$app" "$repo" "$ref") || release_status=$?
fi
case $release_status in
    0)
        mode=release
        IFS=$'\t' read -r ref asset_url asset_sha <<< "$release"
        [[ -n $ref && -n $asset_url && -n $asset_sha ]] \
            || die 'invalid release metadata'
        tag=${ref//[^a-zA-Z0-9_.-]/-}
        [[ $tag != [.-]* ]] || tag=_$tag
        tag=${tag:0:128}
        # Release images never overwrite the source build's :latest tag.
        [[ $tag != latest ]] || die 'release needs a version tag'
        ;;
    3)
        [[ -z $version ]] || die "no published release for version $version"
        [[ $ref != latest ]] || die 'no latest release found'
        command -v git >/dev/null || die 'Git is required for source builds'
        git check-ref-format "refs/heads/$ref" >/dev/null 2>&1 \
            || die 'invalid GIT_REF'
        # Exact ref matching peels annotated tags without app code execution.
        remote_refs=$(git ls-remote -- "$repo" refs/heads/main \
            "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}") \
            || die 'could not resolve remote refs'
        main_sha='' branch_sha='' tag_sha='' peeled_sha=''
        while read -r sha remote_ref; do
            [[ $sha =~ ^[0-9a-f]{40}$ ]] || die 'invalid remote commit hash'
            case $remote_ref in refs/heads/main) main_sha=$sha ;; esac
            case $remote_ref in
                "refs/heads/$ref") branch_sha=$sha ;;
                "refs/tags/$ref") tag_sha=$sha ;;
                "refs/tags/$ref^{}") peeled_sha=$sha ;;
            esac
        done <<< "$remote_refs"
        if [[ $ref =~ ^[0-9a-f]{40}$ ]]; then
            commit=$ref
            tag=$ref
            if [[ $commit == "$main_sha" ]]; then tag=latest; fi
        else
            [[ -z $branch_sha || -z $tag_sha ]] \
                || die 'ambiguous branch/tag name'
            commit=${branch_sha:-${peeled_sha:-$tag_sha}}
            [[ -n $commit ]] || die "remote ref not found: $ref"
            tag=${ref//[^a-zA-Z0-9_.-]/-}
            [[ $tag != [.-]* ]] || tag=_$tag
            tag=${tag:0:128}
            if [[ $ref == main ]]; then tag=latest; fi
        fi
        [[ $tag != latest || $commit == "$main_sha" ]] \
            || die 'latest is reserved for current main'
        ;;
    *) die 'could not resolve release; refusing a source fallback' ;;
esac
image=$image_repo:$tag
build_context=''
container=''
cleanup() {
    trap '' INT TERM
    if [[ -n $build_context ]]; then rm -rf -- "$build_context"; fi
    if [[ -n $container ]]; then
        "$engine" stop --time 2 "$container" >/dev/null 2>&1 || true
        if ! $debug; then
            "$engine" rm "$container" >/dev/null 2>&1 || true
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if $build || ! "$engine" image inspect "$image" >/dev/null 2>&1; then
    if [[ $mode == release ]]; then
        printf 'Packaging %s from its published web ZIP...\n' "$image"
        build_context=$(mktemp -d)
        web_root=$(uv run --no-project "$script_dir/release.py" \
            unpack "$asset_url" "$asset_sha" "$build_context/dist")
        cp "$script_dir/nginx.conf" "$build_context/nginx.conf"
        # UID 101 needs readable files even with a private host umask.
        chmod -R a+rX "$build_context/dist"
        DOCKER_BUILDKIT=1 "$engine" build --target release \
            --file "$script_dir/Containerfile" --tag "$image" \
            --build-arg "WEB_DIR=$web_root" "$build_context"
        rm -rf -- "$build_context"
        build_context=''
    else
        printf 'Building %s with %s (%s -> %s)...\n' \
            "$image" "$engine" "$ref" "$commit"
        DOCKER_BUILDKIT=1 "$engine" build --target source \
            --file "$script_dir/Containerfile" --tag "$image" \
            --build-arg "REPO_URL=$repo" --build-arg "GIT_REF=$commit" \
            --build-arg "WEB_DIR=$web_dir" "$script_dir"
    fi
else
    printf 'Reusing %s with %s.\n' "$image" "$engine"
fi
# The expansion also handles empty arrays on Bash 3.2 with nounset.
container=$("$engine" run --detach --network=none --read-only \
    --user=101:101 \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --pids-limit=64 --memory=256m --cpus=1 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
    ${run_options[@]+"${run_options[@]}"} "$image")
if $debug; then
    printf 'Debug container: %s\n' "$container"
    printf 'Logs: %s logs %s\n' "$engine" "$container"
    printf 'Remove after debugging: %s rm %s\n' "$engine" "$container"
fi
relay_options=()
if $detached; then relay_options+=(--detach); fi
if $debug; then relay_options+=(--debug); fi
if ! uv run --no-project "$script_dir/relay.py" \
    "$engine" "$container" "$port" \
    ${relay_options[@]+"${relay_options[@]}"}; then
    die 'host relay failed'
fi
trap - EXIT INT TERM
