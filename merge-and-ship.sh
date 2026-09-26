#!/usr/bin/env bash
set -euo pipefail

branch=$(git symbolic-ref --short HEAD)

if [[ "$branch" == "master" ]]; then
  echo "Already on master — nothing to merge." >&2
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Uncommitted changes on '$branch' — commit or stash them first." >&2
  exit 1
fi

git switch master
git merge --no-ff "$branch"
git push origin master

echo "Merged and pushed — cleaning up '$branch'..."
git branch -D "$branch"
if git ls-remote --exit-code origin "$branch" &>/dev/null; then
  git push origin --delete "$branch"
fi

echo "Applying DB migrations..."
/var/www/retold/venv/bin/python -m backend.migrate

echo "Rebuilding frontend..."
(cd /var/www/retold/frontend && npm run build)

echo "Checking for in-flight jobs..."
running=$(/var/www/retold/venv/bin/python -c "
import asyncio, asyncpg
from backend.config import settings
async def main():
    conn = await asyncpg.connect(settings.DATABASE_URL, ssl='require', statement_cache_size=0)
    try:
        rows = await conn.fetch(\"SELECT id, status FROM jobs WHERE status IN ('queued','running')\")
    finally:
        await conn.close()
    for r in rows:
        print(f'  {r[\"id\"]} ({r[\"status\"]})')
asyncio.run(main())
")
if [[ -n "$running" ]]; then
  echo "Warning: restarting will interrupt these in-flight job(s) (auto-refunded, but lost):" >&2
  echo "$running" >&2
  read -r -p "Continue anyway? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted before restart — branch is already merged; rerun the deploy steps manually once jobs finish." >&2; exit 1; }
fi

echo "Restarting backend..."
sudo systemctl restart retold

echo "Verifying deploy..."
expected_sha=$(git rev-parse --short HEAD)
health=""
for _ in $(seq 1 10); do
  health=$(curl -sf http://127.0.0.1:8001/health 2>/dev/null || true)
  [[ -n "$health" ]] && break
  sleep 1
done
if [[ -z "$health" ]]; then
  echo "Backend did not come up after restart!" >&2
  exit 1
fi
if [[ "$health" != *"$expected_sha"* ]]; then
  echo "Warning: /health doesn't report the expected version ($expected_sha):" >&2
  echo "  $health" >&2
  exit 1
fi
echo "Backend healthy: $health"
