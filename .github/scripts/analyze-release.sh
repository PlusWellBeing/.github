#!/bin/bash
# analyze-release.sh — Send collected context through Claude for smoke test proposals
#
# Usage:
#   # From a CI-created context issue:
#   ./analyze-release.sh --context 210
#
#   # From a local context JSON file:
#   ./analyze-release.sh --context-file context.json
#
#   # Full pipeline (collect + analyze in one shot, requires MONDAY_TOKEN too):
#   ./analyze-release.sh --repo platform --branch master [--pr 42]
#
# AI Backend (set one):
#   AWS Bedrock (org):  export AWS_REGION=us-east-1  (uses IAM credentials)
#   Anthropic (local):  export ANTHROPIC_API_KEY='sk-ant-...'
#
# Requires: jq, aws CLI or curl
# For --context: gh CLI
# For --repo: MONDAY_TOKEN, gh CLI

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../smoke-test-config.json"
PROMPT_FILE="$SCRIPT_DIR/../prompts/smoke-test-analysis.md"

# --- Argument parsing ---
CONTEXT_ISSUE=""
CONTEXT_FILE=""
REPO_NAME=""
BRANCH=""
PR_NUMBER=""
OUTPUT_FILE=""
CREATE_ISSUE="false"

usage() {
  echo "Usage:"
  echo "  $0 --context <issue-number>           # Read context from GitHub issue"
  echo "  $0 --context-file <context.json>       # Read context from local file"
  echo "  $0 --repo <name> --branch <branch>     # Collect + analyze in one shot"
  echo ""
  echo "Options:"
  echo "  --pr            Specific PR number (with --repo mode)"
  echo "  --output        Write proposal JSON to file (default: stdout)"
  echo "  --create-issue  Create a GitHub Issue with the proposal"
  echo ""
  echo "AI Backend (picks first available):"
  echo "  AWS_REGION set + aws CLI    → uses Bedrock"
  echo "  ANTHROPIC_API_KEY set       → uses Anthropic API directly"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)      CONTEXT_ISSUE="$2"; shift 2 ;;
    --context-file) CONTEXT_FILE="$2"; shift 2 ;;
    --repo)         REPO_NAME="$2"; shift 2 ;;
    --branch)       BRANCH="$2"; shift 2 ;;
    --pr)           PR_NUMBER="$2"; shift 2 ;;
    --output)       OUTPUT_FILE="$2"; shift 2 ;;
    --create-issue) CREATE_ISSUE="true"; shift ;;
    -h|--help)      usage ;;
    *)              echo "Unknown option: $1"; usage ;;
  esac
done

if [ -z "$CONTEXT_ISSUE" ] && [ -z "$CONTEXT_FILE" ] && [ -z "$REPO_NAME" ]; then
  echo "Error: specify --context, --context-file, or --repo" >&2
  usage
fi

# --- Detect AI backend ---
AI_BACKEND=""
BEDROCK_MODEL="us.anthropic.claude-sonnet-4-5-20250929-v1:0"
BEDROCK_REGION="${AWS_REGION:-us-east-1}"

if [ -n "${AWS_REGION:-}" ] && command -v aws &> /dev/null; then
  AI_BACKEND="bedrock"
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  AI_BACKEND="anthropic"
else
  echo "Error: No AI backend available." >&2
  echo "  Set AWS_REGION (for Bedrock) or ANTHROPIC_API_KEY (for Anthropic API)" >&2
  exit 1
fi

echo "AI backend: $AI_BACKEND" >&2

# --- Validate ---
if ! command -v jq &> /dev/null; then
  echo "Error: jq is required. Install with: brew install jq" >&2
  exit 1
fi

echo "=== Smoke Test Analyzer ===" >&2

# --- Step 1: Get context ---
CONTEXT=""

if [ -n "$CONTEXT_FILE" ]; then
  echo "Reading context from: $CONTEXT_FILE" >&2
  if [ ! -f "$CONTEXT_FILE" ]; then
    echo "Error: File not found: $CONTEXT_FILE" >&2
    exit 1
  fi
  CONTEXT=$(cat "$CONTEXT_FILE")

elif [ -n "$CONTEXT_ISSUE" ]; then
  echo "Fetching context from issue #$CONTEXT_ISSUE..." >&2
  ISSUE_BODY=$(gh issue view "$CONTEXT_ISSUE" --repo "PlusWellBeing/.github" --json body --jq '.body')
  CONTEXT=$(echo "$ISSUE_BODY" | sed -n '/```json/,/```/p' | sed '1d;$d')

  if [ -z "$CONTEXT" ] || ! echo "$CONTEXT" | jq . > /dev/null 2>&1; then
    echo "Error: Could not extract valid JSON from issue #$CONTEXT_ISSUE" >&2
    exit 1
  fi

elif [ -n "$REPO_NAME" ]; then
  echo "Collecting context for $REPO_NAME..." >&2

  COLLECT_ARGS="--repo $REPO_NAME"
  [ -n "$BRANCH" ] && COLLECT_ARGS="$COLLECT_ARGS --branch $BRANCH"
  [ -n "$PR_NUMBER" ] && COLLECT_ARGS="$COLLECT_ARGS --pr $PR_NUMBER"

  CONTEXT=$("$SCRIPT_DIR/collect-context.sh" $COLLECT_ARGS)

  if [ -z "$CONTEXT" ] || ! echo "$CONTEXT" | jq . > /dev/null 2>&1; then
    echo "Error: collect-context.sh did not produce valid JSON" >&2
    exit 1
  fi
fi

# Extract fields from context
REPO_NAME=$(echo "$CONTEXT" | jq -r '.repo')
PR_NUMBER=$(echo "$CONTEXT" | jq -r '.pr_number')
PR_TITLE=$(echo "$CONTEXT" | jq -r '.pr_title')
PR_BODY=$(echo "$CONTEXT" | jq -r '.pr_body')
DIFF=$(echo "$CONTEXT" | jq -r '.diff')
CHANGED_FILES=$(echo "$CONTEXT" | jq -r '.changed_files | join("\n")')
BOARD_STATES_TEXT=$(echo "$CONTEXT" | jq -r '.board_states_text')

echo "Repo: $REPO_NAME  |  PR #$PR_NUMBER: $PR_TITLE" >&2

# --- Step 2: Build prompt ---
echo "Building prompt..." >&2

PROMPT_TEMPLATE=$(cat "$PROMPT_FILE")

PROMPT="${PROMPT_TEMPLATE//\{\{REPO_NAME\}\}/$REPO_NAME}"
PROMPT="${PROMPT//\{\{PR_TITLE\}\}/$PR_TITLE}"
PROMPT="${PROMPT//\{\{PR_BODY\}\}/$PR_BODY}"
PROMPT="${PROMPT//\{\{CHANGED_FILES\}\}/$CHANGED_FILES}"
PROMPT="${PROMPT//\{\{DIFF\}\}/$DIFF}"
PROMPT="${PROMPT//\{\{BOARD_STATES\}\}/$BOARD_STATES_TEXT}"

# --- Step 3: Call Claude ---
echo "Calling Claude ($AI_BACKEND)..." >&2

if [ "$AI_BACKEND" = "bedrock" ]; then
  BEDROCK_BODY=$(jq -n \
    --arg prompt "$PROMPT" \
    '{
      anthropic_version: "bedrock-2023-05-31",
      max_tokens: 4096,
      messages: [{role: "user", content: $prompt}]
    }')

  CLAUDE_RESPONSE=$(aws bedrock-runtime invoke-model \
    --region "$BEDROCK_REGION" \
    --model-id "$BEDROCK_MODEL" \
    --content-type "application/json" \
    --accept "application/json" \
    --body "$(echo "$BEDROCK_BODY" | base64)" \
    --query 'body' \
    --output text 2>/dev/null | base64 --decode)

  PROPOSAL=$(echo "$CLAUDE_RESPONSE" | jq -r '.content[0].text // empty')

elif [ "$AI_BACKEND" = "anthropic" ]; then
  CLAUDE_REQUEST=$(jq -n \
    --arg prompt "$PROMPT" \
    '{
      model: "claude-sonnet-4-20250514",
      max_tokens: 4096,
      messages: [{role: "user", content: $prompt}]
    }')

  CLAUDE_RESPONSE=$(curl -s "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$CLAUDE_REQUEST")

  PROPOSAL=$(echo "$CLAUDE_RESPONSE" | jq -r '.content[0].text // empty')
fi

if [ -z "$PROPOSAL" ]; then
  echo "Error: No response from Claude" >&2
  echo "Response: $CLAUDE_RESPONSE" >&2
  exit 1
fi

# Validate JSON — try several extraction strategies
if ! echo "$PROPOSAL" | jq . > /dev/null 2>&1; then
  EXTRACTED=$(echo "$PROPOSAL" | sed -n '/^{/,/^}/p')
  if echo "$EXTRACTED" | jq . > /dev/null 2>&1; then
    PROPOSAL="$EXTRACTED"
  else
    EXTRACTED=$(echo "$PROPOSAL" | sed -n '/```json/,/```/p' | sed '1d;$d')
    if echo "$EXTRACTED" | jq . > /dev/null 2>&1; then
      PROPOSAL="$EXTRACTED"
    else
      echo "Error: Claude response is not valid JSON" >&2
      echo "Raw response:" >&2
      echo "$PROPOSAL" >&2
      exit 1
    fi
  fi
fi

# Add metadata
FINAL_PROPOSAL=$(echo "$PROPOSAL" | jq \
  --arg repo "$REPO_NAME" \
  --arg pr "$PR_NUMBER" \
  --arg pr_title "$PR_TITLE" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {metadata: {repo: $repo, pr_number: ($pr | tonumber), pr_title: $pr_title, analyzed_at: $ts}}')

# --- Step 4: Output ---
CHANGE_COUNT=$(echo "$FINAL_PROPOSAL" | jq '.changes | length')
echo "" >&2
echo "Analysis complete: $CHANGE_COUNT proposed changes" >&2

if [ -n "$OUTPUT_FILE" ]; then
  echo "$FINAL_PROPOSAL" | jq . > "$OUTPUT_FILE"
  echo "Proposal written to: $OUTPUT_FILE" >&2
else
  echo "$FINAL_PROPOSAL" | jq .
fi

# --- Optional: Create GitHub Issue with proposal ---
if [ "$CREATE_ISSUE" = "true" ] && [ "$CHANGE_COUNT" -gt 0 ]; then
  echo "" >&2
  echo "Creating GitHub Issue with proposal..." >&2

  SUMMARY=$(echo "$FINAL_PROPOSAL" | jq -r '.summary')
  CHANGES_TABLE=""
  while IFS= read -r row; do
    ACTION=$(echo "$row" | jq -r '.action')
    BOARD=$(echo "$row" | jq -r '.board_name')
    GROUP=$(echo "$row" | jq -r '.group_title')
    NAME=$(echo "$row" | jq -r '.item_name')
    REASON=$(echo "$row" | jq -r '.reason')
    CHANGES_TABLE="$CHANGES_TABLE
| $ACTION | $BOARD | $GROUP | $NAME | $REASON |"
  done < <(echo "$FINAL_PROPOSAL" | jq -c '.changes[]')

  ISSUE_BODY="## Smoke Test Proposal

**Repo:** $REPO_NAME
**PR:** #$PR_NUMBER — $PR_TITLE
**Analyzed:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

### Summary
$SUMMARY

### Proposed Changes

| Action | Board | Group | Test Case | Reason |
|--------|-------|-------|-----------|--------|$CHANGES_TABLE

### Raw Proposal JSON

\`\`\`json
$(echo "$FINAL_PROPOSAL" | jq .)
\`\`\`

---
*Apply with:* \`./apply-changes.sh --issue <this-issue-number>\`"

  ISSUE_URL=$(gh issue create \
    --repo "PlusWellBeing/.github" \
    --title "Smoke Test Proposal: $REPO_NAME PR #$PR_NUMBER" \
    --body "$ISSUE_BODY" \
    --label "smoke-test-proposal" 2>&1) || {
    echo "Warning: Label not found, creating without label..." >&2
    ISSUE_URL=$(gh issue create \
      --repo "PlusWellBeing/.github" \
      --title "Smoke Test Proposal: $REPO_NAME PR #$PR_NUMBER" \
      --body "$ISSUE_BODY" 2>&1)
  }

  echo "Issue created: $ISSUE_URL" >&2
fi
