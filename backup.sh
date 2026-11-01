#!/usr/bin/env bash
# Encrypted PostgreSQL export -> release assets of the PRIVATE backup store repository. Needs: pg_dump 17, age, gh.
# Env: BACKUP_ENV (prod|staging), PROD_DATABASE_URL / STAGING_DATABASE_URL, AGE_RECIPIENTS (space-separated
# age public keys; every backup is decryptable by each), BACKUP_REPO (owner/name of the private store),
# GH_TOKEN (fine-grained token: contents read/write on BACKUP_REPO only), RETENTION_DAYS (default 30).
set -euo pipefail
if [[ "${BACKUP_ENV:-}" == "prod" ]]; then BACKUP_DATABASE_URL="${PROD_DATABASE_URL:-}"; else BACKUP_DATABASE_URL="${STAGING_DATABASE_URL:-}"; fi
if [[ -z "$BACKUP_DATABASE_URL" ]]; then
  echo "::error::No database URL secret for ${BACKUP_ENV:-?}."
  exit 1
fi

umask 077

: "${BACKUP_ENV:?}" "${AGE_RECIPIENTS:?}" "${GH_TOKEN:?}" "${BACKUP_REPO:?}"
export GH_REPO="$BACKUP_REPO"
[[ "$BACKUP_ENV" =~ ^(prod|staging)$ ]] || { echo "BACKUP_ENV must be prod or staging"; exit 2; }
recipient_args=()
for recipient in $AGE_RECIPIENTS; do
  [[ "$recipient" =~ ^age1[a-z0-9]+$ ]] || { echo "AGE_RECIPIENTS must contain only age public keys"; exit 2; }
  recipient_args+=(-r "$recipient")
done
retention_days="${RETENTION_DAYS:-30}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
day="${stamp:0:8}"
tag="backup-${BACKUP_ENV}-${day}"
name="${BACKUP_ENV}-${stamp}.pgdump.age"

export PGSSLMODE=verify-full PGSSLROOTCERT="$PWD/supabase-root-2021.crt" PGCONNECT_TIMEOUT=20
pg_dump --dbname="$BACKUP_DATABASE_URL" --format=custom --compress=6 \
  --schema=auth --schema=public --schema=private --schema=storage --schema=supabase_migrations \
  --file="$work/dump.pgdump" 2>"$work/pg_dump.err" || { sed -E 's#(postgres(ql)?://)[^@ ]*@#\1***@#g' "$work/pg_dump.err" | tail -5; echo "pg_dump failed"; exit 1; }

entries="$(pg_restore --list "$work/dump.pgdump" | grep -c '^[0-9]')"
size="$(stat -c %s "$work/dump.pgdump")"
(( entries >= 500 && size >= 100000 )) || { echo "Dump implausibly small (entries=$entries bytes=$size)"; exit 1; }

age "${recipient_args[@]}" -o "$work/$name" "$work/dump.pgdump"
sha="$(sha256sum "$work/$name" | cut -d' ' -f1)"

gh release view "$tag" >/dev/null 2>&1 \
  || gh release create "$tag" --title "Encrypted ${BACKUP_ENV} backups ${day}" \
       --notes "age-encrypted pg_dump archives. Asset labels are ciphertext SHA-256." --latest=false
gh release upload "$tag" "$work/$name#$sha"

# Read the asset back and compare checksums before reporting success.
mkdir "$work/readback"
gh release download "$tag" --pattern "$name" --dir "$work/readback"
[[ "$(sha256sum "$work/readback/$name" | cut -d' ' -f1)" == "$sha" ]] || { echo "Readback checksum mismatch"; exit 1; }

# Retention: every backup from the last two days, the earliest backup of each older day, nothing older
# than RETENTION_DAYS. Only this environment's backup releases are touched.
now="$(date -u +%s)"
gh api --paginate "repos/$BACKUP_REPO/releases?per_page=100" \
  --jq ".[] | select(.tag_name | startswith(\"backup-${BACKUP_ENV}-\")) | \"\(.id) \(.tag_name)\"" |
  while read -r id release_tag; do
    release_day="${release_tag##*-}"
    age_days=$(( (now - $(date -u -d "$release_day" +%s)) / 86400 ))
    if (( age_days > retention_days )); then
      gh release delete "$release_tag" --yes --cleanup-tag
    elif (( age_days >= 2 )); then
      gh api --paginate "repos/$BACKUP_REPO/releases/$id/assets?per_page=100" --jq '.[] | "\(.name) \(.id)"' |
        sort | tail -n +2 | while read -r _ asset_id; do
          gh api -X DELETE "repos/$BACKUP_REPO/releases/assets/$asset_id"
        done
    fi
  done

echo "backup ok env=${BACKUP_ENV} release=${tag} asset=${name} entries=${entries} dump_bytes=${size} cipher_sha256=${sha}"
