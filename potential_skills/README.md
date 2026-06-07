# Potential Skills

Recurring blind spots promoted from the bug log. Each domain file is a pre-flight checklist — read it before working in that area.

## Rules

1. **2+ occurrences required.** Only promote here after the same class of bug appears in 2+ separate sessions in the bug log.
2. **Pattern-level, not instance-level.** Describe the general rule, not the specific button or view.
3. **Not covered elsewhere.** Don't duplicate CLAUDE.md or docs/.
4. **Actionable.** Each entry is a checkable rule.
5. **One file per domain.** e.g., `ui_testing.md`, `navigation.md`. Create when a domain gets its first promoted pattern.

## Entry format

```
### Short title
First seen: YYYY-MM-DD
Last seen: YYYY-MM-DD
Occurrences: N

**Pattern:** What keeps going wrong.
**Rule:** What to do instead.
**Why it's missed:** Why this isn't obvious from reading the code.
```

## Lifecycle

- **Add** when a bug pattern hits 2+ occurrences in the bug log.
- **Update** `Last seen` and `Occurrences` on each new occurrence.
- **Graduate** to CLAUDE.md or a skill when stable and broadly applicable.
- **Remove** if the issue is fixed structurally (e.g., linter rule, wrapper component).
