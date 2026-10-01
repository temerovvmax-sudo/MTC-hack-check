#!/bin/sh
set -eu
echo "Waiting for postgres at ${POSTGRES_SERVICE_HOST}:${POSTGRES_SERVICE_PORT}"
while ! nc -z "$POSTGRES_SERVICE_HOST" "$POSTGRES_SERVICE_PORT"; do
  sleep 0.5
done
echo "PostgreSQL is accepting connections"
if [ "${1:-serve}" = "serve" ]; then
  python manage.py migrate --no-input
  python manage.py seed_db
  python manage.py collectstatic --no-input
  exec gunicorn root.asgi:application -c scripts/gunicorn.conf.py
fi
exec "$@"
