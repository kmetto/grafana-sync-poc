#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
load_env
GH_REPO="${GITHUB_REPO_URL#https://github.com/}"
GH_REPO="${GH_REPO%.git}"
STAMP="$(date +%s)"
UID_="e2e-$STAMP"
FILE="e2e-$STAMP.json"
body="$(mktemp)"
trap 'rm -f "$body"' EXIT
# Note: Grafana's file parser rejects a bare dashboard without "tags" ("unable to read bytes as a resource").
cat > "$body" <<JSON
{"uid":"$UID_","title":"E2E $STAMP","schemaVersion":41,"tags":["e2e"],"panels":[]}
JSON

# post_file BASE REPO QUERY — echoes HTTP status; response body goes to $resp
resp="$(mktemp)"; trap 'rm -f "$body" "$resp"' EXIT
post_file() {
  curl -s -o "$resp" -w '%{http_code}' -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" -X POST \
    -H 'Content-Type: application/json' --data-binary "@$body" "$1$REPO_API/$2/files/$FILE?$3"
}

echo "1. prod must reject writes (read-only)"
code="$(post_file "$PROD_URL" poc-prod "message=should-fail")"
[[ "$code" =~ ^2 ]] && die "prod accepted a write (HTTP $code) — it must be read-only"
echo "   ok: prod rejected write with HTTP $code: $(jq -r '.message // empty' "$resp" 2>/dev/null)"

echo "2. commit dashboard via dev Grafana (same API the UI uses)"
code="$(post_file "$DEV_URL" poc-dev "ref=dev&message=e2e:%20add%20$FILE")"
[[ "$code" =~ ^2 ]] || die "dev write failed (HTTP $code): $(cat "$resp")"
gh api "repos/$GH_REPO/contents/grafana/$FILE?ref=dev" >/dev/null || die "file not on branch dev"
echo "   ok: grafana/$FILE on dev"

echo "3. prod must NOT have it before merge"
sleep 35
[[ "$(curl -s -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" "$PROD_URL/api/dashboards/uid/$UID_" | jq -r '.dashboard.uid // empty')" == "" ]] \
  || die "dashboard reached prod before merge"
echo "   ok"

echo "4. PR dev -> main and merge"
url="$(gh pr create -R "$GH_REPO" --base main --head dev --title "e2e: promote $FILE" --body "Automated POC check")"
gh pr merge -R "$GH_REPO" "$url" --merge
echo "   merged $url"

echo "5. prod picks it up within 90s"
for _ in $(seq 1 45); do
  got="$(curl -s -u "$GF_ADMIN_USER:$GF_ADMIN_PASSWORD" "$PROD_URL/api/dashboards/uid/$UID_" | jq -r '.dashboard.uid // empty')"
  [[ "$got" == "$UID_" ]] && { echo "   ok: $UID_ in prod"; exit 0; }
  sleep 2
done
die "dashboard $UID_ did not appear in prod"
