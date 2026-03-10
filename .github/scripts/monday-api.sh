#!/bin/bash
# monday-api.sh — Shared Monday.com API helpers for smoke test automation
# Source this file: source "$(dirname "$0")/monday-api.sh"
#
# Requires: MONDAY_TOKEN env var, jq

MONDAY_API="https://api.monday.com/v2"

# Validate dependencies
_monday_check_deps() {
  if [ -z "$MONDAY_TOKEN" ]; then
    echo "Error: MONDAY_TOKEN env var is required." >&2
    echo "  export MONDAY_TOKEN='your_token_here'" >&2
    return 1
  fi
  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required. Install with: brew install jq" >&2
    return 1
  fi
}

# Core API call — sends a JSON payload to Monday GraphQL API
# Usage: monday_query '{"query": "..."}'
monday_query() {
  local payload="$1"
  local response
  response=$(curl -s "$MONDAY_API" \
    -H "Authorization: $MONDAY_TOKEN" \
    -H "Content-Type: application/json" \
    -H "API-Version: 2024-10" \
    -d "$payload")

  # Check for API-level errors
  local error_msg
  error_msg=$(echo "$response" | jq -r '.error_message // empty' 2>/dev/null)
  if [ -n "$error_msg" ]; then
    echo "Monday API error: $error_msg" >&2
    return 1
  fi

  echo "$response"
}

# Get all item IDs from a board (handles pagination)
# Usage: get_board_items "$board_id"
# Returns JSON array: [{"id": "...", "name": "...", "group": {"id": "...", "title": "..."}}]
get_board_items() {
  local board_id="$1"
  local all_items="[]"
  local cursor=""

  # First page
  local query
  query=$(jq -n --arg q "{ boards(ids: [$board_id]) { items_page(limit: 500) { cursor items { id name group { id title } } } } }" '{"query": $q}')
  local response
  response=$(monday_query "$query")

  local items
  items=$(echo "$response" | jq '[.data.boards[0].items_page.items[] | {id, name, group: {id: .group.id, title: .group.title}}]')
  all_items=$(echo "$all_items" "$items" | jq -s 'add')

  cursor=$(echo "$response" | jq -r '.data.boards[0].items_page.cursor // empty')

  # Paginate
  while [ -n "$cursor" ]; do
    query=$(jq -n --arg q "{ next_items_page(limit: 500, cursor: \"$cursor\") { cursor items { id name group { id title } } } }" '{"query": $q}')
    response=$(monday_query "$query")
    items=$(echo "$response" | jq '[.data.next_items_page.items[] | {id, name, group: {id: .group.id, title: .group.title}}]')
    all_items=$(echo "$all_items" "$items" | jq -s 'add')
    cursor=$(echo "$response" | jq -r '.data.next_items_page.cursor // empty')
  done

  echo "$all_items"
}

# Get all groups from a board
# Usage: get_board_groups "$board_id"
# Returns JSON array: [{"id": "...", "title": "..."}]
get_board_groups() {
  local board_id="$1"
  local query
  query=$(jq -n --arg q "{ boards(ids: [$board_id]) { groups { id title } } }" '{"query": $q}')
  local response
  response=$(monday_query "$query")
  echo "$response" | jq '[.data.boards[0].groups[] | {id, title}]'
}

# Get full board state: groups + items + criteria text
# Usage: get_board_state "$board_id" "$criteria_col"
# Returns JSON: { groups: [...], items: [{id, name, group_id, group_title, criteria}] }
get_board_state() {
  local board_id="$1"
  local criteria_col="$2"

  # Fetch groups
  local groups
  groups=$(get_board_groups "$board_id")

  # Fetch items with criteria column values (paginated)
  local all_items="[]"
  local cursor=""

  local query
  query=$(jq -n --arg q "{ boards(ids: [$board_id]) { items_page(limit: 500) { cursor items { id name group { id title } column_values(ids: [\"$criteria_col\"]) { id text } } } } }" '{"query": $q}')
  local response
  response=$(monday_query "$query")

  local items
  items=$(echo "$response" | jq --arg col "$criteria_col" '[.data.boards[0].items_page.items[] | {
    id,
    name,
    group_id: .group.id,
    group_title: .group.title,
    criteria: (.column_values[] | select(.id == $col) | .text // "")
  }]')
  all_items=$(echo "$all_items" "$items" | jq -s 'add')

  cursor=$(echo "$response" | jq -r '.data.boards[0].items_page.cursor // empty')

  while [ -n "$cursor" ]; do
    query=$(jq -n --arg q "{ next_items_page(limit: 500, cursor: \"$cursor\") { cursor items { id name group { id title } column_values(ids: [\"$criteria_col\"]) { id text } } } }" '{"query": $q}')
    response=$(monday_query "$query")
    items=$(echo "$response" | jq --arg col "$criteria_col" '[.data.next_items_page.items[] | {
      id,
      name,
      group_id: .group.id,
      group_title: .group.title,
      criteria: (.column_values[] | select(.id == $col) | .text // "")
    }]')
    all_items=$(echo "$all_items" "$items" | jq -s 'add')
    cursor=$(echo "$response" | jq -r '.data.next_items_page.cursor // empty')
  done

  jq -n --argjson groups "$groups" --argjson items "$all_items" '{groups: $groups, items: $items}'
}

# Create a new item on a board
# Usage: create_item "$board_id" "$group_id" "$name" "$criteria_col" "$criteria"
# Returns the new item ID
create_item() {
  local board_id="$1"
  local group_id="$2"
  local name="$3"
  local criteria_col="$4"
  local criteria="$5"

  local col_values
  col_values=$(jq -n --arg col "$criteria_col" --arg val "$criteria" '{($col): $val}' | jq -c .)

  local query
  query=$(jq -n \
    --arg q "mutation (\$boardId: ID!, \$groupId: String!, \$itemName: String!, \$columnValues: JSON!) { create_item(board_id: \$boardId, group_id: \$groupId, item_name: \$itemName, column_values: \$columnValues) { id } }" \
    --arg boardId "$board_id" \
    --arg groupId "$group_id" \
    --arg itemName "$name" \
    --arg columnValues "$col_values" \
    '{query: $q, variables: {boardId: $boardId, groupId: $groupId, itemName: $itemName, columnValues: $columnValues}}')

  local response
  response=$(monday_query "$query")
  echo "$response" | jq -r '.data.create_item.id'
}

# Update an item's criteria text column
# Usage: update_item_criteria "$board_id" "$item_id" "$criteria_col" "$criteria"
update_item_criteria() {
  local board_id="$1"
  local item_id="$2"
  local criteria_col="$3"
  local criteria="$4"

  local col_values
  col_values=$(jq -n --arg col "$criteria_col" --arg val "$criteria" '{($col): $val}' | jq -c .)

  local query
  query=$(jq -n \
    --arg q "mutation (\$boardId: ID!, \$itemId: ID!, \$columnValues: JSON!) { change_multiple_column_values(board_id: \$boardId, item_id: \$itemId, column_values: \$columnValues) { id } }" \
    --arg boardId "$board_id" \
    --arg itemId "$item_id" \
    --arg columnValues "$col_values" \
    '{query: $q, variables: {boardId: $boardId, itemId: $itemId, columnValues: $columnValues}}')

  local response
  response=$(monday_query "$query")
  echo "$response" | jq -r '.data.change_multiple_column_values.id'
}

# Delete an item
# Usage: delete_item "$item_id"
delete_item() {
  local item_id="$1"

  local query
  query=$(jq -n \
    --arg q "mutation (\$itemId: ID!) { delete_item(item_id: \$itemId) { id } }" \
    --arg itemId "$item_id" \
    '{query: $q, variables: {itemId: $itemId}}')

  local response
  response=$(monday_query "$query")
  echo "$response" | jq -r '.data.delete_item.id'
}

# Reset a single item's checkbox to unchecked
# Usage: reset_checkbox "$board_id" "$item_id" "$checkbox_col"
reset_checkbox() {
  local board_id="$1"
  local item_id="$2"
  local checkbox_col="$3"

  local query
  query=$(jq -n \
    --arg q "mutation { change_column_value(board_id: $board_id, item_id: $item_id, column_id: \"$checkbox_col\", value: \"{\\\"checked\\\": \\\"false\\\"}\") { id } }" \
    '{"query": $q}')

  monday_query "$query" > /dev/null
}

# Reset all checkboxes on a board
# Usage: reset_all_checkboxes "$board_id" "$checkbox_col"
reset_all_checkboxes() {
  local board_id="$1"
  local checkbox_col="$2"

  echo "  Fetching items from board $board_id..." >&2
  local item_ids
  item_ids=$(get_board_items "$board_id" | jq -r '.[].id')

  local count=0
  local total
  total=$(echo "$item_ids" | wc -l | tr -d ' ')

  echo "  Found $total items. Unchecking all..." >&2

  for item_id in $item_ids; do
    reset_checkbox "$board_id" "$item_id" "$checkbox_col"
    count=$((count + 1))
    printf "\r  Progress: %d/%d" "$count" "$total" >&2
  done

  echo "" >&2
  echo "  Done! Reset $count items." >&2
}
