# PRD Template (Markdown Format)

<!--
Token-efficient alternative to prd.json
~60% fewer tokens than JSON equivalent
Used by ralph-format-plan.sh
-->

## Project: [Project Name]
**Branch:** ralph/[feature-name]
**Status:** IN_PROGRESS | COMPLETE

## Description
[2-3 sentence feature description]

---

## User Stories

### US-001: [Title]
**Priority:** 1 (highest)
**Status:** [ ] pending | [x] complete

As a [user type], I want [goal] so that [benefit].

**Acceptance Criteria:**
- [ ] Specific, verifiable criterion (e.g., "GET /api/users returns 200")
- [ ] Another criterion with measurable result (e.g., "User table has email column")
- [ ] Testable condition (e.g., "Login form renders with email and password fields")

**Notes:** [optional]

---

<!-- PR: core-feature -->

### US-002: [Title]
**Priority:** 2
**Status:** [ ] pending

As a [user type], I want [goal] so that [benefit].

**Acceptance Criteria:**
- [ ] Criterion with specific expected behavior
- [ ] Criterion with verifiable state change

---

## Sizing Rules

Each story must:
- Be describable in 2-3 sentences (if not, split it)
- Have 2-5 acceptance criteria
- Be completable in ONE Ralph iteration (~100K tokens)
- Touch 1-5 files maximum
- Take < 15 min human review time

## Phase Order

Stories should be ordered by dependency:
1. Schema/Types (data models, interfaces, DB migrations)
2. Backend (API endpoints, services, business logic)
3. Frontend (UI components, pages, forms)
4. Integration (connecting pieces, hooks, wiring)
5. Testing (minimal ~20% effort, only for NEW tests)
6. Documentation (only if explicitly requested)

## Acceptance Criteria Rules

- Every story MUST have 2-5 acceptance criteria
- Each criterion MUST be objectively verifiable:
  - Can run a test to verify
  - Can check file/endpoint exists
  - Can observe specific behavior
- Use concrete terms: "returns 200", "file exists at X", "renders Y component"
- AVOID vague criteria: "works correctly", "is implemented", "handles errors"

## Implicit Global Criteria

These are NOT listed per story but are ALWAYS enforced:
- Build passes (typecheck, lint, compile)
- All tests pass (unit, integration)
- Code review agents report no major/critical issues (quality, security, performance)

## PR Boundaries (Optional)

For plans with 5+ stories, use PR markers to indicate logical PR boundaries:

```markdown
### US-003: [Last story in first PR]
**Status:** [ ] pending
...

---

<!-- PR: feature-name -->

### US-004: [First story in second PR]
**Status:** [ ] pending
```

PR markers signal when a logical chunk of work is complete and ready for review.
The ralph loop will notify (but not pause) when a chunk completes.

## Completion

Feature complete when:
- All stories have `[x] complete` status
- All acceptance criteria checked
- Tests passing
- Code review agents report no major issues
