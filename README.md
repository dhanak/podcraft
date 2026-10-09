# Storytold WebAssembly containers

Build a Rust browser app in a networked build container. Start unprivileged
NGINX in an offline runtime container. Rust, Trunk, and Git stay in the
build stage.

Host requirements: Git, uv/Python, and a running Podman or Docker engine.
Launcher prefers Podman, then tries Docker. Use rootless Podman where available.
No host Rust installation or source checkout needed.

```bash
./launch.sh wordcraft --detach --name wordcraft
```

Reuse the matching local runtime image by default. Build automatically only
when that image is missing. Pass `--build` to rebuild from the resolved ref:

```bash
./launch.sh wordcraft --build --detach --name wordcraft
./launch.sh --build  # Default app: wordcraft.
```

Open <http://127.0.0.1:8080/?sample>. Runtime uses `--network=none`: no
external network interfaces, DNS access, or published container ports.
A host HTTP relay fetches responses through engine `exec` and container
loopback port 8080. No host directories or sockets are mounted in the runtime.
Inspect the server directly through the engine:

```bash
podman exec wordcraft curl -fsS http://127.0.0.1:8080/?sample
podman stop wordcraft
```

Replace `podman` with `docker` if Docker was selected. Containers are removed
on exit; images remain cached. Without `--detach`, Ctrl-C stops the server.
The relay binds only to host localhost. `PORT` selects its port. Stopping the
container also stops its relay; Ctrl-C stops both in foreground mode.
The relay handles GET/HEAD, streams responses up to 128 MiB, and applies a
30-second timeout. Other HTTP methods are intentionally omitted for static
Trunk apps. Detached relays require a POSIX host (Linux/macOS).

Any repository with an `apps/APP-web` Trunk project follows the same pattern.
App names are not restricted to a predefined list:

```bash
PORT=8081 ./launch.sh gridcraft --detach --name gridcraft
PORT=8082 ./launch.sh vectorcraft --detach --name vectorcraft
PORT=8083 ./launch.sh photocraft --detach --name photocraft
```

The runtime also has a read-only root filesystem, UID/GID 101, no Linux
capabilities, no privilege escalation, and the engine's default seccomp
policy. Limits: 256 MiB memory, one CPU, 64 processes, and a 16 MiB temporary
filesystem with `noexec,nosuid,nodev`. No host directories or engine sockets
are mounted. Only `--build`, `--detach`/`-d`, `--name`, and `--label` options
are accepted. App name can be omitted for wordcraft. Non-localhost
`BIND_ADDRESS` values are rejected.

Resource limits require working cgroup delegation on the engine host. This
Capsule exposes a shared cgroup, so its resource flags cannot be verified as
per-container limits. Verify those limits on the actual host.

The build container may use the network, including while executing upstream
build scripts and Trunk hooks. Runtime restrictions apply to container
processes; the WebAssembly application executes in the browser when loaded.
Containers share the host kernel.

Every launch resolves `GIT_REF` with `git ls-remote` to select the image tag;
host network access is still required. Existing images are reused even if
the upstream ref changed. Use `--build` to update them. When building, the
Containerfile receives and verifies the exact commit SHA. Changed commits
invalidate the source/build cache; unchanged commits reuse it. Resolution
or build failures abort the launch, including failed forced rebuilds.

Image tags reflect the requested ref:

| `GIT_REF` | Image tag |
| --- | --- |
| `main` (default) | `latest` |
| Full SHA matching current `main` | `latest` |
| Other full SHA | That SHA |
| Version tag, e.g. `v0.1.0` | `v0.1.0` |
| Other branch, e.g. `feature/foo` | `feature-foo` |

Version/branch names keep their own tags even if they point at `main`.
Annotated tags resolve to their commit. Ambiguous branch/tag names are
rejected. Image tags replace unsupported characters with `-` and truncate
at 128 characters. `latest` contains `main` from its last successful build.

Override repository, ref, layout, or image repository:

```bash
GIT_REF=v0.1.0 ./launch.sh wordcraft --detach --name wordcraft-v0-1

REPO_URL=https://github.com/storytold/wordcraft.git \
WEB_DIR=apps/wordcraft-web IMAGE=localhost/custom \
CONTAINER_ENGINE=docker ./launch.sh wordcraft
```

`IMAGE` is the image repository without a tag; the launcher supplies the tag.
`GIT_REF` accepts short branch/tag names or full 40-character commit hashes.

Direct build with a resolved commit and compiler/tool overrides:

```bash
commit=$(git ls-remote https://github.com/storytold/wordcraft.git \
  refs/heads/main | cut -f1)
podman build --file Containerfile --tag localhost/wordcraft:latest \
  --build-arg REPO_URL=https://github.com/storytold/wordcraft.git \
  --build-arg GIT_REF="$commit" \
  --build-arg WEB_DIR=apps/wordcraft-web \
  --build-arg RUST_IMAGE=docker.io/library/rust:1-bookworm \
  --build-arg TRUNK_VERSION=0.21.14 .
```

Use the launcher to apply all runtime restrictions. Base image tags track
updates; direct builds can override `RUST_IMAGE` and `SERVER_IMAGE` with
image digests. The Containerfile requires an immutable commit hash.

Scope: Trunk browser applications. Open and Save use browser file access
and downloads. Native CLI/MCP servers and other web build systems need
their own build/entry-point changes. Optional sibling font repositories
are omitted; app defaults apply. Bundled license notices remain in `/licenses`.

References:

- [Wordcraft web build][wordcraft]
- [Trunk](https://github.com/trunk-rs/trunk)
- [Unprivileged NGINX](https://github.com/nginx/docker-nginx-unprivileged)
- [Podman network and runtime options][podman-run]

[wordcraft]: https://github.com/storytold/wordcraft/tree/main/apps/wordcraft-web
[podman-run]: https://docs.podman.io/en/latest/markdown/podman-run.1.html

Offline launcher and relay checks:

```bash
bash test-launch.sh
shellcheck -s bash launch.sh test-launch.sh
ruff check --fix relay.py
ruff format relay.py
ty check relay.py
```
