#!/bin/sh
set -eu
ACCOUNT_ID=${1:-}
case "$ACCOUNT_ID" in
  acct_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
  *) echo 'invalid account id' >&2; exit 1 ;;
esac
REPOSITORY=bhrumom/fabushi
GH_CLI=${GH_CLI:-$(command -v gh || true)}
if [ -z "$GH_CLI" ]; then echo 'gh is required' >&2; exit 1; fi
ENVIRONMENT="chatgpt-auto-confirm-$ACCOUNT_ID"
"$GH_CLI" api --method DELETE "/repos/$REPOSITORY/environments/$ENVIRONMENT" >/dev/null 2>&1 || true
ids=$({ "$GH_CLI" variable get CHATGPT_AUTO_CONFIRM_ACCOUNT_IDS_JSON --repo "$REPOSITORY" --json value --jq .value 2>/dev/null || printf '[]'; })
printf '%s\n' "$ids" | jq -e 'type == "array"' >/dev/null 2>&1 || ids='[]'
filtered=$(jq -c --arg id "$ACCOUNT_ID" '[.[] | select(. != $id)]' <<< "$ids")
"$GH_CLI" variable set CHATGPT_AUTO_CONFIRM_ACCOUNT_IDS_JSON --repo "$REPOSITORY" --body "$filtered" >/dev/null
