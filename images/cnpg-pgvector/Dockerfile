FROM ghcr.io/cloudnative-pg/postgresql:18-bookworm

USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-pgvector \
 && rm -rf /var/lib/apt/lists/*
USER 26
