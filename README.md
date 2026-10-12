# Storytold WebAssembly containers

Deploy the latest published GitHub web ZIP in an unprivileged, offline
NGINX container. Default deployments download no Rust compiler, Trunk, or
Cargo dependencies. Explicit branches and commits can still build from source.

Host requirements: uv/Python and a running Podman or Docker engine.
Launcher prefers Podman, then tries Docker. Use rootless Podman where available.
Git is needed only for source builds. No host Rust installation needed.

```bash
./launch.sh wordcraft --detach --name wordcraft
```

`GIT_REF` defaults to `latest`, meaning GitHub's latest stable release.
The launcher selects its `APP-web-VERSION.zip` asset and uses the actual
release tag for the image, for example `localhost/storytold-wordcraft:v0.5.0`.
Other apps use the same release naming pattern; there is no app allowlist.

Select a version directly, without a `v` prefix:

```bash
./launch.sh wordcraft@0.5.0  # Exact version.
./launch.sh wordcraft@0.5    # Highest stable 0.5.* version.
./launch.sh wordcraft@0      # Highest stable 0.*.* version.
```

`APP@VERSION` overrides `GIT_REF`. Partial versions compare numeric versions
across all release pages, skipping drafts and prereleases. GitHub tags may
include `v`; image tags keep the selected release's actual full tag.
No match aborts deployment without falling back to a source build.

Reuse the matching local runtime image by default. Package an image only
when missing or `--build` is passed. Reusing a release image fetches only
release metadata. `--build` downloads and repackages its web ZIP; it does
not compile a published release. A new latest release selects a new version
tag, leaving already running containers unchanged.

```bash
./launch.sh wordcraft --build --detach --name wordcraft
./launch.sh --build  # Default app: wordcraft.
GIT_REF=v0.5.0 ./launch.sh wordcraft --detach --name wordcraft-v0-5
```

Release ZIPs are bounded to 128 MiB compressed, 512 MiB unpacked, and 4096
entries. The host helper verifies GitHub's SHA-256 digest when published,
rejects traversal paths, symlinks, special files, and encrypted entries, and
accepts a web root at the archive root or one directory down. It requires
a nonempty `index.html`. ZIP contents are treated as data; no hooks run.
Extraction uses a private temporary build context, removed on success or
failure. Config and web files are made readable by container UID 101,
including when the host uses `umask 027` or `077`.
Only the unpacked web files enter the image, including bundled
license notices. The ZIP is not stored in an image layer or a download cache.

An absent release or web ZIP, failed download, or checksum mismatch aborts
deployment. These failures never fall back to compiling `main`.
Host network access is required to resolve release metadata and download
uncached assets. Public GitHub API rate limits apply.

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
The launcher checks HTTP readiness before announcing service. Startup errors
and failed foreground exits print the last 50 container log lines and return
a nonzero status.
The relay handles GET/HEAD, streams responses up to 128 MiB, and applies a
30-second timeout. Other HTTP methods are intentionally omitted for static
Trunk apps. Detached relays require a POSIX host (Linux/macOS).

To debug startup, retain the stopped container:

```bash
./launch.sh wordcraft --debug --name wordcraft-debug
podman logs wordcraft-debug
podman inspect wordcraft-debug
podman rm wordcraft-debug  # After stopping it, if still running.
```

`--debug` preserves the container after exit; runtime restrictions still apply.
Use `bash -x ./launch.sh wordcraft --debug` for a launcher shell trace.
If an existing image has unreadable files, rebuild it explicitly with
`./launch.sh wordcraft --build`; cached images are never repaired implicitly.

Other repositories with matching published web bundles follow the same pattern:

```bash
PORT=8081 ./launch.sh gridcraft --detach --name gridcraft
PORT=8082 ./launch.sh vectorcraft --detach --name vectorcraft
PORT=8083 ./launch.sh photocraft --detach --name photocraft
```

The runtime also has a read-only root filesystem, UID/GID 101, no Linux
capabilities, no privilege escalation, and the engine's default seccomp
policy. Limits: 256 MiB memory, one CPU, 64 processes, and a 16 MiB temporary
filesystem with `noexec,nosuid,nodev`. No host directories or engine sockets
are mounted. Only `--build`, `--detach`/`-d`, `--debug`, `--name`, and `--label`
options are accepted. App name can be omitted for wordcraft. Non-localhost
`BIND_ADDRESS` values are rejected.

Resource limits require working cgroup delegation on the engine host. This
Capsule exposes a shared cgroup, so its resource flags cannot be verified as
per-container limits. Verify those limits on the actual host.

Runtime restrictions apply to container processes; WebAssembly executes in
the browser when loaded. Containers share the host kernel.

Image tags reflect the requested ref:

| `GIT_REF` | Image tag |
| --- | --- |
| Unset or `latest` (default) | Resolved release tag, e.g. `v0.5.0` |
| Published release tag, e.g. `v0.5.0` | `v0.5.0` |
| Explicit `main` | `latest` (source build) |
| Full SHA matching current `main` | `latest` |
| Other full SHA | That SHA |
| Git tag without a release, e.g. `v0.1.0` | `v0.1.0` (source build) |
| Other branch, e.g. `feature/foo` | `feature-foo` |

Release images never use `:latest`; this also avoids reusing an old source
image for the default release deployment. Version/branch names keep their
own tags even if they point at `main`. Image tags replace unsupported
characters with `-` and truncate at 128 characters.

To compile explicitly, select `main`, a branch, or a full commit SHA:

```bash
GIT_REF=main ./launch.sh wordcraft --build
GIT_REF=feature/foo ./launch.sh wordcraft --build
```

Refs without a published GitHub release use the `source` Containerfile
target. Source lookup resolves exact commits with `git ls-remote` on every
launch, including annotated tags; ambiguous branch/tag names are rejected.
The build verifies that commit. Existing images are reused even if a branch
changed; use `--build` to update them. Failed rebuilds abort the launch.
Source builds may use the network, including upstream build scripts and
Trunk hooks. They retain the compiler/cache disk cost of the original path.

Override repository, ref, layout, or image repository:

```bash
GIT_REF=v0.5.0 ./launch.sh wordcraft --detach --name wordcraft-v0-5

REPO_URL=https://github.com/storytold/wordcraft.git \
GIT_REF=main WEB_DIR=apps/wordcraft-web IMAGE=localhost/custom \
CONTAINER_ENGINE=docker ./launch.sh wordcraft
```

`IMAGE` is the image repository without a tag; the launcher supplies the tag.
`GIT_REF` accepts `latest`, exact release tags, short branch/tag names, or
full 40-character commit hashes. `WEB_DIR` applies only to source builds.
Latest-release deployment requires a public GitHub repository.

Direct source build with a resolved commit and compiler/tool overrides:

```bash
commit=$(git ls-remote https://github.com/storytold/wordcraft.git \
  refs/heads/main | cut -f1)
podman build --target source --file Containerfile \
  --tag localhost/wordcraft:latest \
  --build-arg REPO_URL=https://github.com/storytold/wordcraft.git \
  --build-arg GIT_REF="$commit" \
  --build-arg WEB_DIR=apps/wordcraft-web \
  --build-arg RUST_IMAGE=docker.io/library/rust:1-bookworm \
  --build-arg TRUNK_VERSION=0.21.14 .
```

The default Containerfile target is `release`, which copies `WEB_DIR`
(default: `dist`) into NGINX. Use the launcher to download and validate the
bundle and apply runtime restrictions. Podman skips unused Rust stages;
Docker builds enable BuildKit for the same behavior. Base image tags track
updates; direct builds can override `RUST_IMAGE` and `SERVER_IMAGE` with
image digests. The `source` target requires an immutable commit hash.

Scope: Trunk browser applications. Open and Save use browser file access
and downloads. Native CLI/MCP servers and other web build systems need
their own build/entry-point changes. Release bundles preserve upstream assets
and notices. Source builds omit optional sibling font repositories and keep
their license notices in `/licenses`.

References:

- [Wordcraft web build][wordcraft]
- [Wordcraft releases](https://github.com/storytold/wordcraft/releases)
- [GitHub release API][github-releases]
- [Trunk](https://github.com/trunk-rs/trunk)
- [Unprivileged NGINX](https://github.com/nginx/docker-nginx-unprivileged)
- [Podman network and runtime options][podman-run]

[wordcraft]: https://github.com/storytold/wordcraft/tree/main/apps/wordcraft-web
[podman-run]: https://docs.podman.io/en/latest/markdown/podman-run.1.html
[github-releases]: https://docs.github.com/en/rest/releases/releases

Offline launcher, archive, and relay checks:

```bash
bash test-launch.sh
shellcheck -s bash launch.sh test-launch.sh
ruff check --fix relay.py release.py
ruff format relay.py release.py
ty check relay.py release.py
```
