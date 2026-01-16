# Tasks Template (Technical Implementation Format)

<!--
Technical task breakdown with implementation details
Use when input contains specific technical requirements
Used by ralph-format-plan.sh --tasks
-->

## Feature: [Feature Name]
**Branch:** ralph/[feature-name]
**Status:** IN_PROGRESS | COMPLETE

## Overview
[Brief technical summary of what will be implemented]

---

## Phase 1: Schema & Types

### T-001: [Task Title]
**Status:** [ ] pending | [x] complete

[1-2 sentence description of what to implement]

**Implementation:**
- File: `src/types/user.ts`
- Add interface `UserProfile` with fields: id, email, name, createdAt
- Export from `src/types/index.ts`

**Acceptance Criteria:**
- [ ] `UserProfile` interface exists in `src/types/user.ts`
- [ ] Interface exported from barrel file
- [ ] TypeScript compiles without errors

---

<!-- PR: schema-setup -->

## Phase 2: Backend

### T-002: [Task Title]
**Status:** [ ] pending

[1-2 sentence description]

**Implementation:**
- File: `src/api/users.ts`
- Create GET `/api/users/:id` endpoint
- Use `UserProfile` type for response
- Add validation for `id` parameter

**Acceptance Criteria:**
- [ ] GET `/api/users/123` returns 200 with user data
- [ ] GET `/api/users/invalid` returns 400
- [ ] Response matches `UserProfile` schema

---

## Phase 3: Frontend

### T-003: [Task Title]
**Status:** [ ] pending

[1-2 sentence description]

**Implementation:**
- File: `src/components/UserCard.tsx`
- Props: `user: UserProfile`
- Display: avatar, name, email
- Use existing `Card` component as wrapper

**Acceptance Criteria:**
- [ ] Component renders without errors
- [ ] Displays user name and email
- [ ] Matches design system styles

---

## Sizing Rules

Each task must:
- Be describable in 1-2 sentences
- Have specific implementation guidance (files, functions, patterns)
- Have 2-4 acceptance criteria
- Be completable in ONE Ralph iteration (~100K tokens)
- Touch 1-5 files maximum

## Phase Order

Tasks should be ordered by dependency:
1. Schema & Types (interfaces, types, DB migrations)
2. Backend (API endpoints, services, handlers)
3. Frontend (components, pages, forms)
4. Integration (wiring, hooks, connections)
5. Testing (only for NEW tests, ~20% effort)
6. Documentation (only if explicitly requested)

## Acceptance Criteria Rules

- Every task MUST have 2-4 acceptance criteria
- Each criterion MUST be objectively verifiable
- Include specific values: "returns 200", "file exists at X", "renders Y"
- AVOID vague criteria: "works correctly", "is implemented"

## Implicit Global Criteria

These are NOT listed per task but are ALWAYS enforced:
- Build passes (typecheck, lint, compile)
- All tests pass (unit, integration)
- Code review agents report no major/critical issues (quality, security, performance)

## PR Boundaries (Optional)

For plans with 5+ tasks, use PR markers to indicate logical PR boundaries:

```markdown
### T-003: [Last task in first PR]
**Status:** [ ] pending
...

---

<!-- PR: feature-name -->

### T-004: [First task in second PR]
**Status:** [ ] pending
```

PR markers signal when a logical chunk of work is complete and ready for review.
The ralph loop will notify (but not pause) when a chunk completes.

## Completion

Feature complete when:
- All tasks have `[x] complete` status
- All acceptance criteria checked
- Tests passing
- Code review agents report no major issues
