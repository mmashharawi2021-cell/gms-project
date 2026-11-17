# GMS Unified Production Image for Railway / Cloud Deployment
FROM node:22-alpine AS web-build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
COPY apps/admin-web/package.json apps/admin-web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY apps/admin-web/ ./
RUN npm run build

FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 DEBIAN_FRONTEND=noninteractive

# 1. Install Node.js 22 and PostgreSQL 16
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg \
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
 && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /etc/apt/keyrings/postgresql.asc \
 && echo "deb [signed-by=/etc/apt/keyrings/postgresql.asc] http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
 && apt-get update && apt-get install -y --no-install-recommends \
    nodejs \
    postgresql-16 \
    postgresql-client-16 \
 && rm -rf /var/lib/apt/lists/*

# 2. Setup Python API
WORKDIR /srv/api
COPY services/api/pyproject.toml ./
RUN pip install --upgrade pip && pip install .
COPY services/api/ ./
COPY db/sql /srv/db/sql
ENV GMS_SQL_DIR=/srv/db/sql
RUN pip install --no-deps .

# 3. Setup Next.js Standalone
WORKDIR /srv/web
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
COPY --from=web-build /app/.next/standalone ./
COPY --from=web-build /app/.next/static ./.next/static
COPY --from=web-build /app/public ./public

# 4. Entrypoint Script
COPY scripts/railway_entrypoint.sh /srv/entrypoint.sh
RUN chmod +x /srv/entrypoint.sh

EXPOSE 3000
CMD ["/srv/entrypoint.sh"]
