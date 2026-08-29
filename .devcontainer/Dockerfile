# VARIANT_DIGEST pins the base image content so a rebuild reproduces the same package snapshot
# instead of floating with whatever "debian:${VARIANT}" currently resolves to; it must name the
# manifest for VARIANT itself, so update both together. Refresh with:
#   curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/debian:pull" \
#     | grep -o '"token":"[^"]*"' | cut -d'"' -f4 \
#     | xargs -I{} curl -sI -H "Authorization: Bearer {}" \
#         -H "Accept: application/vnd.oci.image.index.v1+json" \
#         "https://registry-1.docker.io/v2/library/debian/manifests/${VARIANT}" \
#     | grep -i docker-content-digest
ARG VARIANT=13
ARG VARIANT_DIGEST=sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1
FROM debian:${VARIANT}@${VARIANT_DIGEST}
# nodejs/npm/g++/python3 are host components for test/node_pty (see test/README.md): a Node runtime to run the
# generated js_of_ocaml/Melange backends under, plus node-gyp's build prerequisites (g++, python3; make
# is already listed above) for node-pty's native PTY addon, which `make node-pty-install` (npm ci)
# compiles from source against this Node build. dialog/whiptail/tmux above are the interactive programs
# and independent oracle those tests (and test/proxy_tmux) drive.
RUN set -eux;\
    apt-get update;\
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends\
  ca-certificates\
  curl\
  g++\
  git\
  make\
  nodejs\
  npm\
  python3\
  ripgrep\
  tmux\
  dialog\
  whiptail\
  wget\
  xz-utils\
;\
    apt-get autoremove -y; apt-get clean -y ; rm -rf /var/lib/apt/lists/*;\
    echo DONE
