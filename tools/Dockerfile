# syntax=docker/dockerfile:1
# sql-ag-lab tools image: host-side helpers that are not part of the frozen runtime image
# (changing runtime/ would invalidate every checkpoint). Used by `./lab media iso`.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
  && apt-get install -y --no-install-recommends xorriso \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --create-home tools
USER 10001
WORKDIR /work
ENTRYPOINT ["xorriso"]
