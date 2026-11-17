#!/bin/bash
set -e

echo "=== Starting GMS All-in-One Production Stack ==="

# 1. Setup directories and start PostgreSQL via native Debian service
mkdir -p /var/run/postgresql /var/lib/postgresql /var/log/postgresql /var/lib/gms/objects /var/lib/gms/backups /tmp
chown -R postgres:postgres /var/run/postgresql /var/lib/postgresql /var/log/postgresql
chmod 777 /tmp /var/run/postgresql

echo "Starting PostgreSQL service..."
if ! pg_lsclusters | grep -q "16"; then
    echo "Creating PostgreSQL 16 cluster..."
    pg_createcluster 16 main --locale=C.UTF-8
fi

# Ensure localhost TCP connections are trusted for internal stack
HBA="/etc/postgresql/16/main/pg_hba.conf"
if [ -f "$HBA" ]; then
    sed -i 's/127.0.0.1\/32.*/127.0.0.1\/32            trust/g' "$HBA"
    sed -i 's/::1\/128.*/::1\/128                 trust/g' "$HBA"
fi

service postgresql start

# 2. Wait for PostgreSQL to accept connections
echo "Waiting for PostgreSQL to accept connections..."
until su - postgres -c "pg_isready" > /dev/null 2>&1; do
    echo "Waiting for postgres..."
    sleep 1
done
echo "PostgreSQL is ready and healthy!"

# 3. Create admin user and database if not exists
su - postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname = 'gms_admin'\" | grep -q 1 || psql -c \"CREATE USER gms_admin WITH SUPERUSER PASSWORD '7fCQLs9qSJtFMJAhdysJka-lP1wfD-duzqHumIHm04U';\""
su - postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname = 'gms'\" | grep -q 1 || psql -c \"CREATE DATABASE gms OWNER gms_admin;\""

# 4. Run GMS migrations & database setup
export GMS_MIGRATION_DATABASE_URL="postgresql://gms_admin:7fCQLs9qSJtFMJAhdysJka-lP1wfD-duzqHumIHm04U@127.0.0.1:5432/gms"
export GMS_DB_APP_USER="gms_app"
export GMS_DB_APP_PASSWORD="5-Ns4ZgVAD9MqEOuOc29on1ydfOalH9l7cLoepgk4rg"
export GMS_DATABASE_URL="postgresql://gms_app:5-Ns4ZgVAD9MqEOuOc29on1ydfOalH9l7cLoepgk4rg@127.0.0.1:5432/gms"
export GMS_JWT_SECRET="${GMS_JWT_SECRET:-iMDgXzuuvLRZ7DXC3_Tp6-GM_4LlOC0IyaGPXE8Ij3IE-xfIzddK7wZnAeXinwsbAxCycGTgmttx7LKGlygqjw}"
export GMS_STORAGE_BACKEND="filesystem"
export GMS_STORAGE_DIR="/var/lib/gms/objects"
export GMS_BACKUP_DIR="/var/lib/gms/backups"

echo "Applying migrations and database setup..."
cd /srv/api
python -m app.ops.dbsetup

# Create or update default manager (permanent password, no forced change)
python -c "
import os, psycopg
from app.security import hash_password

conn = psycopg.connect('postgresql://gms_admin:7fCQLs9qSJtFMJAhdysJka-lP1wfD-duzqHumIHm04U@127.0.0.1:5432/gms')
cur = conn.cursor()
mgr_user = os.environ.get('GMS_MANAGER_USERNAME', 'mmashharawi').strip().lower()
mgr_pass = os.environ.get('GMS_MANAGER_PASSWORD', os.environ.get('ADMIN_PASSWORD', 'TempPass2026')).strip()

cur.execute('SELECT id FROM gms.app_users WHERE username = %s', (mgr_user,))
row = cur.fetchone()

pw_hash = hash_password(mgr_pass)
if not row:
    cur.execute('''
        INSERT INTO gms.app_users (username, password_hash, full_name, role, must_change_password)
        VALUES (%s, %s, 'مهند المشهراوي', 'manager', false)
    ''', (mgr_user, pw_hash))
    conn.commit()
    print(f'Created permanent manager: {mgr_user}')
else:
    # Always keep permanent password without forcing change
    if os.environ.get('GMS_MANAGER_PASSWORD') or os.environ.get('ADMIN_PASSWORD'):
        cur.execute('''
            UPDATE gms.app_users 
            SET password_hash = %s, must_change_password = false 
            WHERE username = %s
        ''', (pw_hash, mgr_user))
        conn.commit()
        print(f'Updated manager {mgr_user} password from environment variable.')
    else:
        cur.execute('UPDATE gms.app_users SET must_change_password = false WHERE username = %s', (mgr_user,))
        conn.commit()
conn.close()
"

# 5. Start FastAPI backend on 127.0.0.1:8000
echo "Starting FastAPI backend on 127.0.0.1:8000..."
uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000 --proxy-headers &

# Wait for API to be healthy
until curl -fsS http://127.0.0.1:8000/health > /dev/null 2>&1; do
    echo "Waiting for API to respond..."
    sleep 1
done
echo "FastAPI backend is ready and healthy!"

# 6. Start Next.js Web frontend on $PORT (Railway provides PORT, default 3000)
export PORT="${PORT:-3000}"
export HOSTNAME="0.0.0.0"
export GMS_API_INTERNAL_URL="http://127.0.0.1:8000"

# Ensure both port 3000 and port 8080 forward properly
if [ "$PORT" != "8080" ]; then
    socat TCP-LISTEN:8080,fork,reuseaddr TCP:127.0.0.1:$PORT &
fi
if [ "$PORT" != "3000" ]; then
    socat TCP-LISTEN:3000,fork,reuseaddr TCP:127.0.0.1:$PORT &
fi

echo "Starting Next.js frontend on port $PORT..."
cd /srv/web
exec node server.js
