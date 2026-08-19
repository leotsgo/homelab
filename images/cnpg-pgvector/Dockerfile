# Pinned to a GA release (the old `18-bookworm` tag froze at 18rc1 when CNPG moved
# to flavor-suffixed tags).
FROM ghcr.io/cloudnative-pg/postgresql:18.6-standard-bookworm

# barman-cli-cloud is in NO operand image flavor, `standard` included: CNPG dropped the
# barman-cloud binaries in favour of the CNPG-I plugin. The cluster still backs up via
# `backup.barmanObjectStore`, whose archive_command shells out to
# barman-cloud-wal-archive, so it must be installed here — without it WAL archiving fails
# silently and pg_wal grows without bound. python3-boto3 (S3/B2) is a hard dependency.
#
# Renovate bumps the FROM line but nothing rebuilds this image, so the published tag and
# this file drift apart: after a bump, rebuild and push a new `<version>-<rev>` tag and
# move the cluster's imageName to it, or the bump is a no-op.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-18-pgvector barman-cli-cloud \
 && rm -rf /var/lib/apt/lists/*
USER 26
