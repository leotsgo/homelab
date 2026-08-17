# Pinned to a GA release (the old `18-bookworm` tag froze at 18rc1 when CNPG moved
# to flavor-suffixed tags). `standard-bookworm` is the drop-in of the old default.
FROM ghcr.io/cloudnative-pg/postgresql:18.6-standard-bookworm

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-pgvector \
 && rm -rf /var/lib/apt/lists/*
USER 26
