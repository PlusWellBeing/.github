You are analyzing a code change to determine if smoke test boards on Monday.com need to be updated.

## Context

Repository: **{{REPO_NAME}}**
PR Title: **{{PR_TITLE}}**
PR Body:
{{PR_BODY}}

## Changed Files

{{CHANGED_FILES}}

## Diff

```
{{DIFF}}
```

## Current Board State

The following boards are the smoke test checklists that QA uses to verify each release. Each board has groups (test categories) and items (individual test cases) with acceptance criteria.

{{BOARD_STATES}}

## Instructions

Analyze the code diff and determine what changes (if any) are needed to the smoke test boards.

### Rules

1. **Only propose changes for user-visible behavior changes.** Skip:
   - Internal refactors that don't change behavior
   - Dependency updates (unless they change UI/UX)
   - CI/CD pipeline changes
   - Documentation-only changes
   - Test file changes (unless they reveal new features)
   - Code style / formatting changes

2. **Be conservative.** When unsure whether a change affects user-visible behavior, do NOT propose changes. An empty changes array is perfectly valid and preferred over false positives.

3. **Available actions:**
   - `ADD` — New test case needed for new functionality
   - `UPDATE` — Existing test case criteria need updating due to changed behavior
   - `DELETE` — Test case is no longer relevant (feature removed)

4. **For ADD actions:** Choose the most appropriate existing group. Look at the group titles and existing items to determine where the new test case logically belongs.

5. **For UPDATE actions:** You MUST include the `item_id` of the existing item being updated.

6. **For DELETE actions:** You MUST include the `item_id` of the item to delete. Only propose deletion when a feature is clearly removed, not just refactored.

7. **For backend/platform repos:** Determine which front-end boards are affected based on what the API changes enable. A backend change that only affects the provider portal should only update the Provider board, not all boards.

8. **Acceptance criteria format:** Write clear, testable steps that a QA tester can follow. Use the format: "Given [precondition] → [action] → [expected result]". Keep them concise.

## Output Format

Respond with ONLY valid JSON (no markdown code fences, no explanation text):

```json
{
  "summary": "Brief description of what changed and why (or 'No smoke test changes needed')",
  "changes": [
    {
      "action": "ADD|UPDATE|DELETE",
      "board_name": "PWA|Ops|Provider|Mobile|Patient",
      "board_id": "the board ID from the board state above",
      "group_id": "the group ID where this item belongs",
      "group_title": "human-readable group name",
      "item_id": "required for UPDATE and DELETE, omit for ADD",
      "item_name": "test case name",
      "acceptance_criteria": "required for ADD and UPDATE, omit for DELETE",
      "reason": "why this change is needed"
    }
  ]
}
```

If no changes are needed, return:
```json
{
  "summary": "No smoke test changes needed. [brief reason]",
  "changes": []
}
```
