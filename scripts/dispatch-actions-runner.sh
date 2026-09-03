#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPOSITORY=bhrumom/fabushi
AUTH_PATH=${CHATGPT_CODEX_AUTH_PATH:-"$HOME/.codex/auth.json"}
SESSION_COOKIES_PATH=${CHATGPT_SESSION_COOKIES_PATH:-"$HOME/Library/Application Support/Mahayana/plugins/chatgpt-auto-confirm/session-cookies.json"}
ACCOUNT_ID=${CHATGPT_ACCOUNT_ID:-}

if command -v gh >/dev/null 2>&1; then
  GH_CLI=$(command -v gh)
elif [ -x /opt/homebrew/bin/gh ]; then
  GH_CLI=/opt/homebrew/bin/gh
elif [ -x /usr/local/bin/gh ]; then
  GH_CLI=/usr/local/bin/gh
else
  echo "没有找到 gh；请先安装 GitHub CLI 并完成 gh auth login。" >&2
  exit 1
fi
if [ ! -s "$AUTH_PATH" ]; then
  echo "没有可上传的 ChatGPT 登录凭证：$AUTH_PATH" >&2
  exit 1
fi
if [ ! -s "$SESSION_COOKIES_PATH" ]; then
  echo "没有可上传的 ChatGPT 会话凭证：${SESSION_COOKIES_PATH}；请先运行 login_and_sync_actions 完成登录。" >&2
  exit 1
fi
AUTH_SIZE=$(base64 < "$AUTH_PATH" | wc -c | tr -d ' ')
if [ "$AUTH_SIZE" -ge 47000 ]; then
  echo "ChatGPT 登录凭证超过 GitHub Secret 大小限制。" >&2
  exit 1
fi
SESSION_COOKIES_SIZE=$(base64 < "$SESSION_COOKIES_PATH" | wc -c | tr -d ' ')
if [ "$SESSION_COOKIES_SIZE" -ge 47000 ]; then
  echo "ChatGPT 会话凭证超过 GitHub Secret 大小限制。" >&2
  exit 1
fi
if [ -n "$ACCOUNT_ID" ]; then
  case "$ACCOUNT_ID" in
    acct_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
    *) echo "账号 id 无效。" >&2; exit 1 ;;
  esac
  ENVIRONMENT="chatgpt-auto-confirm-$ACCOUNT_ID"
  # The environment is created with a main-only deployment policy.  Secrets
  # remain environment-scoped so one account can never overwrite another.
  printf '%s\n' '{"wait_timer":0,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' |
    "$GH_CLI" api --method PUT \
      "/repos/$REPOSITORY/environments/$ENVIRONMENT" \
      --input - >/dev/null
  "$GH_CLI" api --method POST \
    "/repos/$REPOSITORY/environments/$ENVIRONMENT/deployment-branch-policies" \
    -f name=main >/dev/null 2>&1 || true
  base64 < "$AUTH_PATH" |
    "$GH_CLI" secret set CHATGPT_CODEX_AUTH_B64 --repo "$REPOSITORY" --env "$ENVIRONMENT"
  base64 < "$SESSION_COOKIES_PATH" |
    "$GH_CLI" secret set CHATGPT_SESSION_COOKIES_B64 --repo "$REPOSITORY" --env "$ENVIRONMENT"
  if ! "$GH_CLI" secret list --repo "$REPOSITORY" --env "$ENVIRONMENT" --json name --jq \
    'map(.name) | index("CHATGPT_AUTO_CONFIRM_STATE_KEY") != null' | grep -q true; then
    openssl rand -base64 48 |
      "$GH_CLI" secret set CHATGPT_AUTO_CONFIRM_STATE_KEY --repo "$REPOSITORY" --env "$ENVIRONMENT"
  fi
  ids=$({ "$GH_CLI" variable get CHATGPT_AUTO_CONFIRM_ACCOUNT_IDS_JSON --repo "$REPOSITORY" --json value --jq .value 2>/dev/null || printf '[]'; })
  printf '%s\n' "$ids" | jq -e 'type == "array"' >/dev/null 2>&1 || ids='[]'
  merged=$(jq -c --arg id "$ACCOUNT_ID" '(. + [$id]) | unique | .[0:10]' <<< "$ids")
  "$GH_CLI" variable set CHATGPT_AUTO_CONFIRM_ACCOUNT_IDS_JSON --repo "$REPOSITORY" --body "$merged"
else
  base64 < "$AUTH_PATH" |
    "$GH_CLI" secret set CHATGPT_CODEX_AUTH_B64 --repo "$REPOSITORY"
  base64 < "$SESSION_COOKIES_PATH" |
    "$GH_CLI" secret set CHATGPT_SESSION_COOKIES_B64 --repo "$REPOSITORY"
fi

if [ -z "$ACCOUNT_ID" ] && ! "$GH_CLI" secret list --repo "$REPOSITORY" --json name --jq \
  'map(.name) | index("CHATGPT_AUTO_CONFIRM_STATE_KEY") != null' |
  grep -q true; then
  openssl rand -base64 48 |
    "$GH_CLI" secret set CHATGPT_AUTO_CONFIRM_STATE_KEY --repo "$REPOSITORY"
fi

if [ "${CHATGPT_AUTO_CONFIRM_DISPATCH:-true}" = "true" ]; then
  if [ -n "$ACCOUNT_ID" ]; then
    "$GH_CLI" workflow run chatgpt-auto-confirm-runner.yml \
      --repo "$REPOSITORY" --ref main \
      -f account_id="$ACCOUNT_ID" -f smoke_only=true -f restore_latest_credentials=true
  else
    "$GH_CLI" workflow run chatgpt-auto-confirm-runner.yml \
      --repo "$REPOSITORY" --ref main
  fi
  echo "已启动 GitHub Actions 持续运行器。"
else
  echo "已同步 GitHub Actions 登录凭证。"
fi
