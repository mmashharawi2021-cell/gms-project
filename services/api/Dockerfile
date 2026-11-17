# GMS API image. Python 3.12 + PostgreSQL 16 client tools (pg_dump/pg_restore must match the server major version).
FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
 && install -d /usr/share/postgresql-common/pgdg \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
 && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends postgresql-client-16 \
 && apt-get purge -y gnupg && rm -rf /var/lib/apt/lists/*
WORKDIR /srv/api
COPY services/api/pyproject.toml ./
RUN pip install --upgrade pip && pip install .
COPY services/api/ ./
COPY db/sql /srv/db/sql
ENV GMS_SQL_DIR=/srv/db/sql
RUN pip install --no-deps . && useradd --system --uid 10001 gms && mkdir -p /var/lib/gms/objects /var/lib/gms/backups && chown -R gms /var/lib/gms
USER gms
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD curl -fsS http://127.0.0.1:8000/health || exit 1
CMD ["uvicorn", "app.main:create_app", "--factory", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--workers", "2"]
