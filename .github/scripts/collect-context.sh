#!/bin/bash
# collect-context.sh — Collect PR diff + board state for smoke test analysis
#
# This runs in CI (no API keys needed beyond Monday + GitHub).
# Outputs a JSON context file that analyze-release.sh consumes locally.
#
# Usage:
#   CI:     ./collect-context.sh --ci --create-issue
#   Local:  ./collect-context.sh --repo platform --branch master [--pr 42]
#
# Requires: MONDAY_TOKEN, gh CLI, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../smoke-test-config.json"

# Source Monday API helpers
source "$SCRIPT_DIR/monday-api.sh"

# --- Argument parsing ---
MODE=""
REPO_NAME=""
BRANCH=""
PR_NUMBER=""
OUTPUT_FILE=""
CREATE_ISSUE="false"

usage() {
  echo "Usage:"
  echo "  $0 --repo <repo-name> --branch <branch> [--pr <number>] [--output <file>] [--create-issue]"
  echo "  $0 --ci [--create-issue]"
  echo ""
  echo "Collects diff + board state into a context JSON file."
  echo "Run analyze-release.sh locally to send it through Claude."
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO_NAME="$2"; MODE="local"; shift 2 ;;
    --branch)  BRANCH="$2"; shift 2 ;;
    --pr)      PR_NUMBER="$2"; shift 2 ;;
    --ci)      MODE="ci"; shift ;;
    --output)  OUTPUT_FILE="$2"; shift 2 ;;
    --create-issue) CREATE_ISSUE="true"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "Error: specify --repo or --ci" >&2
  usage
fi

# --- Validate dependencies ---
_monday_check_deps || exit 1

if ! command -v gh &> /dev/null; then
  echo "Error: gh CLI is required. Install with: brew install gh" >&2
  exit 1
fi

# --- Resolve repo and PR ---
if [ "$MODE" = "ci" ]; then
  FULL_REPO="${GITHUB_REPOSITORY:-}"
  if [ -z "$FULL_REPO" ]; then
    echo "Error: GITHUB_REPOSITORY not set. Are you running in GitHub Actions?" >&2
    exit 1
  fi
  REPO_NAME=$(basename "$FULL_REPO")
  BRANCH="${GITHUB_REF_NAME:-master}"

  MERGE_COMMIT="${GITHUB_SHA:-}"
  IS_TAG="false"
  if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    IS_TAG="true"
  fi

  if [ -n "$MERGE_COMMIT" ]; then
    # Try to find PR associated with this commit
    PR_NUMBER=$(gh pr list --repo "$FULL_REPO" --state merged --search "$MERGE_COMMIT" --json number --jq '.[0].number' 2>/dev/null || echo "")

    # For tag pushes, also try finding the PR via the merge commit
    if [ -z "$PR_NUMBER" ] && [ "$IS_TAG" = "true" ]; then
      PR_NUMBER=$(gh api "repos/$FULL_REPO/commits/$MERGE_COMMIT/pulls" --jq '.[0].number' 2>/dev/null || echo "")
    fi
  fi

  # For tag-based repos, resolve the default branch for fallback PR lookup
  if [ "$IS_TAG" = "true" ]; then
    BRANCH=$(gh api "repos/$FULL_REPO" --jq '.default_branch' 2>/dev/null || echo "master")
    echo "  Tag-based trigger ($GITHUB_REF_NAME), using default branch: $BRANCH" >&2
  fi
else
  FULL_REPO="PlusWellBeing/$REPO_NAME"
  BRANCH="${BRANCH:-master}"
fi

echo "=== Smoke Test Context Collector ===" >&2
echo "Repo: $FULL_REPO" >&2
echo "Branch: $BRANCH" >&2

# --- Step 1: Collect diff ---
echo "Step 1: Collecting diff..." >&2

if [ -n "$PR_NUMBER" ]; then
  echo "  Analyzing PR #$PR_NUMBER" >&2
  PR_TITLE=$(gh pr view "$PR_NUMBER" --repo "$FULL_REPO" --json title --jq '.title')
  PR_BODY=$(gh pr view "$PR_NUMBER" --repo "$FULL_REPO" --json body --jq '.body')
  DIFF=$(gh pr diff "$PR_NUMBER" --repo "$FULL_REPO" 2>/dev/null || echo "(diff unavailable)")
  CHANGED_FILES=$(gh pr view "$PR_NUMBER" --repo "$FULL_REPO" --json files --jq '.files[].path')
else
  echo "  Finding latest merged PR on $BRANCH..." >&2
  PR_JSON=$(gh pr list --repo "$FULL_REPO" --state merged --base "$BRANCH" --limit 1 --json number,title,body)
  PR_NUMBER=$(echo "$PR_JSON" | jq -r '.[0].number // empty')

  if [ -z "$PR_NUMBER" ]; then
    echo "Error: No merged PRs found on $BRANCH" >&2
    exit 1
  fi

  echo "  Analyzing PR #$PR_NUMBER" >&2
  PR_TITLE=$(echo "$PR_JSON" | jq -r '.[0].title')
  PR_BODY=$(echo "$PR_JSON" | jq -r '.[0].body')
  DIFF=$(gh pr diff "$PR_NUMBER" --repo "$FULL_REPO" 2>/dev/null || echo "(diff unavailable)")
  CHANGED_FILES=$(gh pr view "$PR_NUMBER" --repo "$FULL_REPO" --json files --jq '.files[].path')
fi

echo "  PR: $PR_TITLE" >&2

# Truncate diff if too large (use temp file to avoid SIGPIPE with head in pipefail mode)
DIFF_LINES=$(printf '%s\n' "$DIFF" | wc -l | tr -d ' ')
if [ "$DIFF_LINES" -gt 2000 ]; then
  echo "  Warning: Diff is $DIFF_LINES lines, truncating to 2000" >&2
  DIFF_TMPFILE=$(mktemp)
  printf '%s\n' "$DIFF" > "$DIFF_TMPFILE"
  DIFF=$(head -2000 "$DIFF_TMPFILE")
  rm -f "$DIFF_TMPFILE"
  DIFF="$DIFF
... (truncated from $DIFF_LINES lines)"
fi

# --- Step 2: Determine target boards ---
echo "Step 2: Determining target boards..." >&2

TARGET_BOARDS=""

CROSS_CUTTING=$(jq --arg repo "$REPO_NAME" '.cross_cutting_repos[$repo] // empty' "$CONFIG_FILE")
if [ -n "$CROSS_CUTTING" ] && [ "$CROSS_CUTTING" != "null" ]; then
  TARGET_BOARDS=$(echo "$CROSS_CUTTING" | jq -r '.[]')
  echo "  Cross-cutting repo → targeting boards: $(echo "$TARGET_BOARDS" | tr '\n' ', ')" >&2
else
  TARGET_BOARDS=$(jq -r --arg repo "$REPO_NAME" '
    .boards | to_entries[] | select(.value.repos[] == $repo) | .key
  ' "$CONFIG_FILE")

  if [ -z "$TARGET_BOARDS" ]; then
    echo "  Warning: No boards configured for repo '$REPO_NAME'" >&2
    echo '{"summary": "No boards configured for this repository", "changes": []}'
    exit 0
  fi
  echo "  Targeting boards: $(echo "$TARGET_BOARDS" | tr '\n' ', ')" >&2
fi

# --- Step 3: Fetch board state ---
echo "Step 3: Fetching board state..." >&2

BOARD_STATES_JSON="[]"
BOARD_STATES_TEXT=""

for board_name in $TARGET_BOARDS; do
  BOARD_ID=$(jq -r --arg name "$board_name" '.boards[$name].board_id' "$CONFIG_FILE")
  CRITERIA_COL=$(jq -r --arg name "$board_name" '.boards[$name].criteria_col' "$CONFIG_FILE")

  echo "  Fetching $board_name board ($BOARD_ID)..." >&2
  STATE=$(get_board_state "$BOARD_ID" "$CRITERIA_COL")

  # Append to JSON array
  BOARD_STATES_JSON=$(echo "$BOARD_STATES_JSON" | jq \
    --arg name "$board_name" \
    --arg bid "$BOARD_ID" \
    --argjson state "$STATE" \
    '. + [{board_name: $name, board_id: $bid, state: $state}]')

  # Build human-readable text for the prompt
  BOARD_STATES_TEXT="$BOARD_STATES_TEXT
### $board_name Board (ID: $BOARD_ID)

Groups:
$(echo "$STATE" | jq -r '.groups[] | "- \(.title) (id: \(.id))"')

Items:
$(echo "$STATE" | jq -r '.items[] | "- [\(.group_title)] \(.name) (id: \(.id))\n  Criteria: \(.criteria // "(none)")"')

---
"
done

# --- Step 4: Build context JSON ---
echo "Step 4: Building context..." >&2

CONTEXT=$(jq -n \
  --arg repo "$REPO_NAME" \
  --arg full_repo "$FULL_REPO" \
  --arg branch "$BRANCH" \
  --arg pr_number "$PR_NUMBER" \
  --arg pr_title "$PR_TITLE" \
  --arg pr_body "$PR_BODY" \
  --arg diff "$DIFF" \
  --arg changed_files "$CHANGED_FILES" \
  --argjson board_states "$BOARD_STATES_JSON" \
  --arg board_states_text "$BOARD_STATES_TEXT" \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    repo: $repo,
    full_repo: $full_repo,
    branch: $branch,
    pr_number: ($pr_number | tonumber),
    pr_title: $pr_title,
    pr_body: $pr_body,
    diff: $diff,
    changed_files: ($changed_files | split("\n") | map(select(. != ""))),
    board_states: $board_states,
    board_states_text: $board_states_text,
    collected_at: $collected_at
  }')

echo "" >&2
echo "Context collected for PR #$PR_NUMBER" >&2

if [ -n "$OUTPUT_FILE" ]; then
  echo "$CONTEXT" | jq . > "$OUTPUT_FILE"
  echo "Context written to: $OUTPUT_FILE" >&2
else
  echo "$CONTEXT" | jq .
fi

# --- Optional: Create GitHub Issue with context ---
if [ "$CREATE_ISSUE" = "true" ]; then
  echo "" >&2
  echo "Creating GitHub Issue with context..." >&2

  CHANGED_LIST=$(echo "$CHANGED_FILES" | head -30 | sed 's/^/- /')
  FILE_COUNT=$(echo "$CHANGED_FILES" | wc -l | tr -d ' ')

  ISSUE_BODY="## Smoke Test Context — Ready for Analysis

**Repo:** $REPO_NAME
**PR:** #$PR_NUMBER — $PR_TITLE
**Branch:** $BRANCH
**Collected:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

### Changed Files ($FILE_COUNT)

$CHANGED_LIST

### Board State Snapshot

$BOARD_STATES_TEXT

### Context JSON

\`\`\`json
$(echo "$CONTEXT" | jq .)
\`\`\`

---
**Next step:** Run locally:
\`\`\`bash
./analyze-release.sh --context <this-issue-number>
# or
./analyze-release.sh --context-file context.json
\`\`\`"

  ISSUE_URL=$(gh issue create \
    --repo "PlusWellBeing/.github" \
    --title "Smoke Test Context: $REPO_NAME PR #$PR_NUMBER" \
    --body "$ISSUE_BODY" \
    --label "smoke-test-context" 2>&1) || {
    echo "Warning: Label not found, creating without label..." >&2
    ISSUE_URL=$(gh issue create \
      --repo "PlusWellBeing/.github" \
      --title "Smoke Test Context: $REPO_NAME PR #$PR_NUMBER" \
      --body "$ISSUE_BODY" 2>&1)
  }

  echo "Issue created: $ISSUE_URL" >&2
fi
