#!/usr/bin/env bash
# Usage: e2e.sh <client-id> — dev folder → client repo `dev` → PR → `main` → client prod, plus isolation from other clients.
source "$(dirname "$0")/lib.sh"
load_env
CLIENT="${1:-}"; require_client "$CLIENT"
GH_REPO="$(client_field "$CLIENT" repo)"
PROD_URL="$(client_field "$CLIENT" prod_url)"
DEV_REPO="$CLIENT-dev"; PROD_REPO="$CLIENT-prod"
STAMP="$(date +%s)"
UID_="$CLIENT-e2e-$STAMP"
FILE="e2e-$STAMP.json"

body="$(mktemp)"; resp="$(mktemp)"
trap 'rm -f "$body" "$resp"' EXIT
# Note: Grafana's file parser rejects a bare dashboard without "tags" ("unable to read bytes as a resource").
cat > "$body" <<JSON
{"uid":"$UID_","title":"E2E $CLIENT $STAMP","schemaVersion":41,"tags":["e2e"],"panels":[]}
JSON

# post_file BASE REPO QUERY — echoes HTTP status; response body goes to $resp
post_file() {
  curl -s -o "$resp" -w '%{http_code}' -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" -X POST \
    -H 'Content-Type: application/json' --data-binary "@$body" "$1$REPO_API/$2/files/$FILE?$3"
}
dash_uid_on() { curl -s -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" "$1/api/dashboards/uid/$UID_" | jq -r '.dashboard.uid // empty'; }

echo "1. $CLIENT prod must reject writes (read-only)"
code="$(post_file "$PROD_URL" "$PROD_REPO" "message=should-fail")"
[[ "$code" =~ ^2 ]] && die "prod accepted a write (HTTP $code) — it must be read-only"
echo "   ok: prod rejected write with HTTP $code: $(jq -r '.message // empty' "$resp" 2>/dev/null)"

echo "2. commit dashboard via $CLIENT's dev folder"
code="$(post_file "$DEV_URL" "$DEV_REPO" "ref=dev&message=e2e:%20add%20$FILE")"
[[ "$code" =~ ^2 ]] || die "dev write failed (HTTP $code): $(cat "$resp")"
gh api "repos/$GH_REPO/contents/grafana/$FILE?ref=dev" >/dev/null || die "file not on $GH_REPO dev"
echo "   ok: grafana/$FILE on $GH_REPO dev"

echo "3. $CLIENT prod must NOT have it before merge"
sleep 35
[[ -z "$(dash_uid_on "$PROD_URL")" ]] || die "dashboard reached prod before merge"
echo "   ok"

echo "4. PR dev -> main in $GH_REPO and merge"
url="$(gh pr create -R "$GH_REPO" --base main --head dev --title "e2e: promote $FILE" --body "Automated POC check")"
gh pr merge -R "$GH_REPO" "$url" --merge
echo "   merged $url"

echo "5. $CLIENT prod picks it up within 90s"
found=""
for _ in $(seq 1 45); do
  [[ "$(dash_uid_on "$PROD_URL")" == "$UID_" ]] && { found=1; break; }
  sleep 2
done
[[ -n "$found" ]] || die "dashboard $UID_ did not appear in $CLIENT prod"
echo "   ok: $UID_ in $CLIENT prod"

echo "6. other clients are isolated"
for other in $(clients); do
  [[ "$other" == "$CLIENT" ]] && continue
  orepo="$(client_field "$other" repo)"
  if gh api "repos/$orepo/contents/grafana/$FILE?ref=dev" >/dev/null 2>&1 \
     || gh api "repos/$orepo/contents/grafana/$FILE?ref=main" >/dev/null 2>&1; then
    die "$FILE leaked into $orepo"
  fi
  [[ -z "$(dash_uid_on "$(client_field "$other" prod_url)")" ]] || die "$UID_ leaked into $other prod"
  echo "   ok: not in $orepo or $other prod"
done
