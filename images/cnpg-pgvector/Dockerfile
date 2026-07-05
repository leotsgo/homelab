# Thin CloudNativePG image with pgvector, for the shared `homelab` cluster.
# BookOrbit needs the `vector` extension; pg_trgm and uuid-ossp already ship in
# the CNPG contrib set. Rebuild when bumping the Postgres minor or pgvector.
FROM ghcr.io/cloudnative-pg/postgresql:18-bookworm

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-pgvector \
 && rm -rf /var/lib/apt/lists/*
USER 26
