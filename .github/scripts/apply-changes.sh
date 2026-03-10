#!/bin/bash
# apply-changes.sh — Interactive review + apply smoke test proposals to Monday.com
#
# Usage:
#   ./apply-changes.sh --issue 207              # From a GitHub issue
#   ./apply-changes.sh --file proposal.json     # From a local file
#   ./apply-changes.sh --issue 207 --dry-run    # Preview only
#
# Requires: MONDAY_TOKEN, gh CLI, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../smoke-test-config.json"

# Source Monday API helpers
source "$SCRIPT_DIR/monday-api.sh"

# --- Argument parsing ---
ISSUE_NUMBER=""
INPUT_FILE=""
DRY_RUN="false"
RESET_CHECKBOXES="false"

usage() {
  echo "Usage:"
  echo "  $0 --issue <number> [--dry-run] [--reset]"
  echo "  $0 --file <proposal.json> [--dry-run] [--reset]"
  echo ""
  echo "Options:"
  echo "  --issue      GitHub issue number containing the proposal"
  echo "  --file       Local JSON file with the proposal"
  echo "  --dry-run    Preview changes without applying"
  echo "  --reset      Reset checkboxes on affected boards after applying"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)   ISSUE_NUMBER="$2"; shift 2 ;;
    --file)    INPUT_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    --reset)   RESET_CHECKBOXES="true"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [ -z "$ISSUE_NUMBER" ] && [ -z "$INPUT_FILE" ]; then
  echo "Error: specify --issue or --file" >&2
  usage
fi

# --- Validate dependencies ---
_monday_check_deps || exit 1

# --- Step 1: Fetch proposal ---
echo "=== Smoke Test Change Applicator ==="
echo ""

PROPOSAL=""

if [ -n "$INPUT_FILE" ]; then
  echo "Reading proposal from: $INPUT_FILE"
  if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: File not found: $INPUT_FILE" >&2
    exit 1
  fi
  PROPOSAL=$(cat "$INPUT_FILE")
elif [ -n "$ISSUE_NUMBER" ]; then
  echo "Fetching proposal from issue #$ISSUE_NUMBER..."
  ISSUE_BODY=$(gh issue view "$ISSUE_NUMBER" --repo "PlusWellBeing/.github" --json body --jq '.body')

  # Extract JSON block from issue body
  PROPOSAL=$(echo "$ISSUE_BODY" | sed -n '/```json/,/```/p' | sed '1d;$d')

  if [ -z "$PROPOSAL" ]; then
    echo "Error: No JSON block found in issue #$ISSUE_NUMBER" >&2
    exit 1
  fi
fi

# Validate JSON
if ! echo "$PROPOSAL" | jq . > /dev/null 2>&1; then
  echo "Error: Invalid JSON in proposal" >&2
  exit 1
fi

SUMMARY=$(echo "$PROPOSAL" | jq -r '.summary')
CHANGE_COUNT=$(echo "$PROPOSAL" | jq '.changes | length')
REPO=$(echo "$PROPOSAL" | jq -r '.metadata.repo // "unknown"')
PR_NUM=$(echo "$PROPOSAL" | jq -r '.metadata.pr_number // "?"')

echo ""
echo "Repo: $REPO  |  PR: #$PR_NUM"
echo "Summary: $SUMMARY"
echo "Changes: $CHANGE_COUNT proposed"
echo ""

if [ "$CHANGE_COUNT" -eq 0 ]; then
  echo "No changes to apply."
  exit 0
fi

if [ "$DRY_RUN" = "true" ]; then
  echo "[DRY RUN MODE — no changes will be applied]"
  echo ""
fi

# --- Step 2: Interactive review ---
APPLIED=0
SKIPPED=0
FAILED=0
AFFECTED_BOARDS=""

for i in $(seq 0 $((CHANGE_COUNT - 1))); do
  CHANGE=$(echo "$PROPOSAL" | jq -c ".changes[$i]")

  ACTION=$(echo "$CHANGE" | jq -r '.action')
  BOARD_NAME=$(echo "$CHANGE" | jq -r '.board_name')
  BOARD_ID=$(echo "$CHANGE" | jq -r '.board_id')
  GROUP_ID=$(echo "$CHANGE" | jq -r '.group_id')
  GROUP_TITLE=$(echo "$CHANGE" | jq -r '.group_title')
  ITEM_ID=$(echo "$CHANGE" | jq -r '.item_id // empty')
  ITEM_NAME=$(echo "$CHANGE" | jq -r '.item_name')
  CRITERIA=$(echo "$CHANGE" | jq -r '.acceptance_criteria // empty')
  REASON=$(echo "$CHANGE" | jq -r '.reason')

  echo "────────────────────────────────────────────"
  echo "[$((i + 1))/$CHANGE_COUNT] $ACTION on $BOARD_NAME board"
  echo "  Group: \"$GROUP_TITLE\""
  echo "  Name:  \"$ITEM_NAME\""

  if [ -n "$ITEM_ID" ]; then
    echo "  Item ID: $ITEM_ID"
  fi

  if [ -n "$CRITERIA" ]; then
    echo "  Criteria: $CRITERIA"
  fi

  echo "  Reason: $REASON"
  echo ""

  if [ "$DRY_RUN" = "true" ]; then
    echo "  [DRY RUN] Would $ACTION"
    APPLIED=$((APPLIED + 1))
    continue
  fi

  # Prompt for action
  while true; do
    printf "  Apply? [y/n/s(kip)/q(uit)] "
    read -r answer
    case "$answer" in
      y|Y|yes)
        break
        ;;
      n|N|no|s|S|skip)
        SKIPPED=$((SKIPPED + 1))
        echo "  Skipped."
        continue 2  # skip to next change
        ;;
      q|Q|quit)
        echo ""
        echo "Quit. Applied: $APPLIED  Skipped: $((SKIPPED + CHANGE_COUNT - i))  Failed: $FAILED"
        exit 0
        ;;
      *)
        echo "  Please enter y, n, s, or q"
        ;;
    esac
  done

  # --- Step 3: Apply the change ---
  CRITERIA_COL=$(jq -r --arg name "$BOARD_NAME" '.boards[$name].criteria_col' "$CONFIG_FILE")

  case "$ACTION" in
    ADD)
      echo "  Creating item..."
      NEW_ID=$(create_item "$BOARD_ID" "$GROUP_ID" "$ITEM_NAME" "$CRITERIA_COL" "$CRITERIA")
      if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "null" ]; then
        echo "  Created item: $NEW_ID"
        APPLIED=$((APPLIED + 1))
        AFFECTED_BOARDS="$AFFECTED_BOARDS $BOARD_NAME"
      else
        echo "  FAILED to create item" >&2
        FAILED=$((FAILED + 1))
      fi
      ;;

    UPDATE)
      if [ -z "$ITEM_ID" ]; then
        echo "  FAILED: UPDATE requires item_id" >&2
        FAILED=$((FAILED + 1))
        continue
      fi
      echo "  Updating item $ITEM_ID..."
      RESULT=$(update_item_criteria "$BOARD_ID" "$ITEM_ID" "$CRITERIA_COL" "$CRITERIA")
      if [ -n "$RESULT" ] && [ "$RESULT" != "null" ]; then
        echo "  Updated item: $RESULT"
        APPLIED=$((APPLIED + 1))
        AFFECTED_BOARDS="$AFFECTED_BOARDS $BOARD_NAME"
      else
        echo "  FAILED to update item" >&2
        FAILED=$((FAILED + 1))
      fi
      ;;

    DELETE)
      if [ -z "$ITEM_ID" ]; then
        echo "  FAILED: DELETE requires item_id" >&2
        FAILED=$((FAILED + 1))
        continue
      fi
      echo "  Deleting item $ITEM_ID..."
      RESULT=$(delete_item "$ITEM_ID")
      if [ -n "$RESULT" ] && [ "$RESULT" != "null" ]; then
        echo "  Deleted item: $RESULT"
        APPLIED=$((APPLIED + 1))
        AFFECTED_BOARDS="$AFFECTED_BOARDS $BOARD_NAME"
      else
        echo "  FAILED to delete item" >&2
        FAILED=$((FAILED + 1))
      fi
      ;;

    *)
      echo "  Unknown action: $ACTION" >&2
      FAILED=$((FAILED + 1))
      ;;
  esac

  echo ""
done

# --- Step 4: Optional checkbox reset ---
if [ "$RESET_CHECKBOXES" = "true" ] && [ "$APPLIED" -gt 0 ]; then
  # Deduplicate affected boards
  UNIQUE_BOARDS=$(echo "$AFFECTED_BOARDS" | tr ' ' '\n' | sort -u | grep -v '^$')

  if [ -n "$UNIQUE_BOARDS" ]; then
    echo ""
    echo "────────────────────────────────────────────"
    echo "Reset checkboxes on affected boards?"
    echo "  Boards: $(echo "$UNIQUE_BOARDS" | tr '\n' ', ' | sed 's/,$//')"
    printf "  Reset? [y/n] "
    read -r reset_answer

    if [ "$reset_answer" = "y" ] || [ "$reset_answer" = "Y" ]; then
      for board_name in $UNIQUE_BOARDS; do
        BOARD_ID=$(jq -r --arg name "$board_name" '.boards[$name].board_id' "$CONFIG_FILE")
        CHECKBOX_COL=$(jq -r --arg name "$board_name" '.boards[$name].checkbox_col' "$CONFIG_FILE")
        echo ""
        echo "Resetting $board_name board..."
        reset_all_checkboxes "$BOARD_ID" "$CHECKBOX_COL"
      done
    else
      echo "  Skipping checkbox reset."
    fi
  fi
fi

# --- Step 5: Summary ---
echo ""
echo "════════════════════════════════════════════"
echo "Summary"
echo "  Applied: $APPLIED"
echo "  Skipped: $SKIPPED"
echo "  Failed:  $FAILED"
echo "════════════════════════════════════════════"
