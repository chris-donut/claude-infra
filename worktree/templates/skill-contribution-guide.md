# Skill Contribution Guide

## How the Pipeline Learns

After every successful review cycle, the system compares:
1. **Builder's self-score** (what the builder thought of their own work)
2. **Reviewer's findings** (what the reviewer actually found)

The gap between these two signals tells us where to improve.

## Contribution Types

### 1. Blind Spot Detection
When the reviewer catches issues the builder didn't self-identify:
- Add these patterns to the self-score checklist
- Update worker-CLAUDE.md with new items to watch for

### 2. Calibration Correction
When the builder scores themselves 8+ on a dimension but reviewer finds major issues:
- Adjust the rubric descriptions for that score level
- The builder was over-confident — tighten the bar

### 3. New Checklist Item
When a new type of issue appears that isn't in any existing checklist:
- Add it to the review checklist in worker-CLAUDE.md
- Consider adding it to quality-gate.sh Tier 1 if automatable

## Contribution Report Format

Reports are saved to `.worktree-shared/skill-contributions/<task-id>.json`

```json
{
  "task": "original task title",
  "worker": "worker-1",
  "timestamp": "2026-03-01T12:00:00Z",
  "blind_spots": [
    {
      "file": "src/parser.ts",
      "line": 42,
      "category": "correctness",
      "severity": "major",
      "problem": "Null deref on empty input"
    }
  ],
  "calibration_gaps": {
    "correctness": {
      "builder_score": 9,
      "reviewer_issue_weight": 4,
      "assessment": "over-confident"
    }
  },
  "total_self_issues": 2,
  "total_reviewer_issues": 5
}
```

## How It Feeds Back

The quality-ratchet reads contribution reports to generate rubric improvement
tasks at low priority. Over time this tightens the scoring criteria and
reduces blind spots across all workers.
