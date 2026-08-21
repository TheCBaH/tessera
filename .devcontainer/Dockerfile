ARG VARIANT=13
FROM debian:${VARIANT}
RUN set -eux;\
    apt-get update;\
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends\
  ca-certificates\
  curl\
  git\
  make\
  ripgrep\
  wget\
  xz-utils\
;\
    apt-get autoremove -y; apt-get clean -y ; rm -rf /var/lib/apt/lists/*;\
    echo DONE
