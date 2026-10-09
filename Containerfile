ARG RUST_IMAGE=docker.io/library/rust:1-bookworm
ARG SERVER_IMAGE=docker.io/nginxinc/nginx-unprivileged:stable-alpine

FROM ${RUST_IMAGE} AS builder
ARG TRUNK_VERSION=0.21.14
RUN rustup target add wasm32-unknown-unknown \
    && cargo install --locked --version "${TRUNK_VERSION}" trunk

ARG REPO_URL=https://github.com/storytold/wordcraft.git
# Launcher resolves branches/tags on the host; cache by immutable commit.
ARG GIT_REF
WORKDIR /src
RUN test "${#GIT_REF}" = 40 \
    && printf '%s\n' "${GIT_REF}" | grep -Eq '^[0-9a-f]{40}$' \
    && git init . \
    && git remote add origin "${REPO_URL}" \
    && git fetch --depth 1 origin "${GIT_REF}" \
    && git checkout --detach FETCH_HEAD \
    && test "$(git rev-parse HEAD)" = "${GIT_REF}"

ARG WEB_DIR=apps/wordcraft-web
WORKDIR /src/${WEB_DIR}
# Optional sibling font repositories are intentionally omitted.
RUN trunk build --release --locked --dist /dist \
    && test -s /dist/index.html

# Preserve notices for the app and its bundled assets.
WORKDIR /src
RUN mkdir /licenses \
    && find . -path './.git' -prune -o -path './target' -prune -o \
       -type f \( -iname '*license*' -o -iname 'OFL*' \
       -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' \
       -o -name NOTICE -o -name ATTRIBUTION.md \) \
       -exec cp --parents '{}' /licenses/ \;

FROM ${SERVER_IMAGE}
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /dist/ /usr/share/nginx/html/
COPY --from=builder /licenses/ /licenses/
USER 101:101
EXPOSE 8080
ENTRYPOINT ["nginx"]
CMD ["-g", "daemon off;"]
