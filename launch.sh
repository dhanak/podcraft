#!/usr/bin/env bash
set -euo pipefail

die() {
    printf 'launch: %s\n' "$*" >&2
    exit 1
}

if [[ ${1-} == --help || ${1-} == -h ]]; then
    cat <<'HELP'
Usage: ./launch.sh [APP] [--build] [--detach] [--name NAME]
                   [--label KEY=VALUE]

Serve a Storytold Trunk/WebAssembly app. Default: wordcraft.
Reuse its local image; build only if missing or --build is passed.
Runtime has no external network. Host relay serves HTTP on localhost.
Only build/detach/name/label options are accepted.

Environment:
  CONTAINER_ENGINE  podman or docker; auto-detect working engine by default
  REPO_URL          default: https://github.com/storytold/APP.git
  GIT_REF           branch, tag, or full commit; default: main
  WEB_DIR           relative web directory; default: apps/APP-web
  PORT              host relay port, 1..65535; default: 8080
  IMAGE             image repository; default: localhost/storytold-APP

Branches/tags resolve to current commits on every launch.
main/current-main commit uses :latest; other refs get their own image tag.
HELP
    exit 0
fi

app=wordcraft
if (( $# )) && [[ $1 != -* ]]; then app=$1; shift; fi
[[ $app =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die 'invalid app name'
# Whitelist prevents run options from undoing containment.
run_options=()
detached=false
build=false
while (( $# )); do
    case $1 in
        --build) build=true; shift ;;
        --detach|-d) detached=true; shift ;;
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
ref=${GIT_REF-main}
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
command -v git >/dev/null || die 'Git is required to resolve revisions'
command -v uv >/dev/null || die 'uv is required for the host HTTP relay'
git check-ref-format "refs/heads/$ref" >/dev/null 2>&1 \
    || die 'invalid GIT_REF'

# Exact ref matching also peels annotated tags without executing app code.
remote_refs=$(git ls-remote -- "$repo" refs/heads/main \
    "refs/heads/$ref" "refs/tags/$ref" "refs/tags/$ref^{}") \
    || die 'could not resolve remote refs'
main_sha='' branch_sha='' tag_sha='' peeled_sha=''
while read -r sha remote_ref; do
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || die 'invalid remote commit hash'
    case $remote_ref in
        refs/heads/main) main_sha=$sha ;;
    esac
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
    [[ -z $branch_sha || -z $tag_sha ]] || die 'ambiguous branch/tag name'
    commit=${branch_sha:-${peeled_sha:-$tag_sha}}
    [[ -n $commit ]] || die "remote ref not found: $ref"
    tag=${ref//[^a-zA-Z0-9_.-]/-}
    [[ $tag != [.-]* ]] || tag=_$tag
    tag=${tag:0:128}
    if [[ $ref == main ]]; then tag=latest; fi
fi
[[ $tag != latest || $commit == "$main_sha" ]] \
    || die 'latest is reserved for current main'
image=$image_repo:$tag

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
if $build || ! "$engine" image inspect "$image" >/dev/null 2>&1; then
    printf 'Building %s with %s (%s -> %s)...\n' \
        "$image" "$engine" "$ref" "$commit"
    "$engine" build --file "$script_dir/Containerfile" --tag "$image" \
        --build-arg "REPO_URL=$repo" --build-arg "GIT_REF=$commit" \
        --build-arg "WEB_DIR=$web_dir" "$script_dir"
else
    printf 'Reusing %s with %s.\n' "$image" "$engine"
fi
printf 'Serving %s at http://127.0.0.1:%s/ (offline runtime).\n' \
    "$image" "$port"
# The expansion also handles empty arrays on Bash 3.2 with nounset.
container=$("$engine" run --detach --rm --network=none --read-only \
    --user=101:101 \
    --cap-drop=ALL --security-opt=no-new-privileges \
    --pids-limit=64 --memory=256m --cpus=1 \
    --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
    ${run_options[@]+"${run_options[@]}"} "$image")
cleanup() {
    trap '' INT TERM
    "$engine" stop --time 2 "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
relay_options=()
if $detached; then relay_options+=(--detach); fi
if ! uv run --no-project "$script_dir/relay.py" \
    "$engine" "$container" "$port" \
    ${relay_options[@]+"${relay_options[@]}"}; then
    die 'host relay failed'
fi
trap - EXIT INT TERM
