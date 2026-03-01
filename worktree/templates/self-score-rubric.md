# Self-Score Rubric v1

Reference document for worker self-scoring. The same rubric is embedded in
worker-CLAUDE.md; this standalone version can be versioned and improved
independently.

## Dimension Definitions

### spec_compliance (weight: 1.5x)
- 10: Every requirement implemented, nothing extra
- 8: All requirements met, minor interpretation differences
- 6: Most requirements met, 1-2 minor gaps
- 4: Significant requirements missing
- 2: Wrong problem solved

### correctness (weight: 2x)
- 10: All paths correct, edge cases handled, no possible runtime errors
- 8: Core logic correct, minor edge cases may be unhandled
- 6: Works for happy path, some edge cases fail
- 4: Core logic has bugs
- 2: Fundamentally broken

### security (weight: 2x)
- 10: No vulnerabilities, proper input validation, secrets handled correctly
- 8: Secure for intended use, minor hardening possible
- 6: No critical vulnerabilities but missing some validation
- 4: Has exploitable vulnerability
- 2: Hardcoded secrets or injection risk

### readability (weight: 1x)
- 10: Self-documenting, clear names, obvious flow
- 8: Easy to follow, minor naming improvements possible
- 6: Understandable with effort, some confusing parts
- 4: Hard to follow, unclear names, tangled logic

### convention (weight: 1x)
- 10: Perfectly matches codebase patterns
- 8: Follows conventions with minor deviations
- 6: Mixed patterns, some inconsistency

### testing (weight: 1x)
- 10: Comprehensive tests, edge cases covered, TDD followed
- 8: Good coverage of main paths
- 6: Basic happy-path tests only
- 4: Tests exist but don't verify real behavior
- 0: No tests

### simplicity (weight: 1x)
- 10: Minimal code, no unnecessary abstractions
- 8: Mostly simple, minor simplification possible
- 6: Some over-engineering or unnecessary complexity

## Overall Score Calculation

```
overall = (
    correctness * 2 +
    security * 2 +
    spec_compliance * 1.5 +
    readability * 1 +
    convention * 1 +
    testing * 1 +
    simplicity * 1
) / 9.5
```

## Thresholds

| Overall | Action |
|---------|--------|
| >= 7    | Submit with `--result success` |
| 5-6.9   | Fix lowest dimensions first, re-score |
| < 5     | Mark `--result failed` with reason |

Any single dimension <= 5 → MUST fix before submitting.

## Structured Issue Format

When listing `self_identified_issues`, use this format:

```
category/severity file:line -- Problem -> Remedy
```

Categories: `correctness`, `security`, `architecture`, `testing`, `style`, `performance`
Severity: `critical`, `major`, `minor`
