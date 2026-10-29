# Flutter Client AI Development

## Execution and Authorization

Investigate, implement, validate, self-review, and deliver continuously after task assignment without separate stage approvals. Check worktrees, local AGENTS, applicable LESSONS, and business references; preserve user edits. Ask for essential missing information, product decisions, or scope expansion. Do not repeat existing authorization requests. Commits, pushes, formal releases, and Issue writes each need explicit authorization. Commit directly to main, children before parent pointers.

Shared mechanics are in the [parent AI workflow](https://github.com/leonzy/roomtone/blob/main/docs/en/ai-development.md). Synchronize the Chinese version; local business, device, and validation requirements take precedence.

## Validation and Evidence

After Dart changes run `dart format lib/ test/`, `flutter analyze`, and relevant `flutter test`; broaden for shared behavior. Exercise UI using the parent's Docker browser workflow. Native audio, permissions, background lifecycle, hot updates, and Bundle behavior need affected-device/OS checks. Web results do not replace native acceptance; documentation-only edits do not require the entire App suite.

Record repository, full Issue references, baseline/final SHA or uncommitted fingerprint, environment, time, commands, observed outcomes, logs/screenshots, and relevant Not run checks. Bug tests must fail for the intended behavior against isolated old code; use deliberate break checks where useful. Changes to code/dependencies/generated output require affected checks again. Follow required CI for the same pushed SHA; cancelled/skipped does not pass.

Local AGENTS and the development guide own business/platform rules; record backend, Flutter, and Bundle publication repositories and installed versions separately.

## Issue Triage

Unresolved Issue triage covers the parent and all recursive submodules, deduplicated and fully paginated, retaining assignees rather than only checking this repository. From the parent run `node scripts/ai-review-context.mjs issues --output /tmp/songloft-issues-<unique-id>.json`. Standalone checkouts obtain the parent's .gitmodules inventory and complete coverage using read-only GitHub APIs.

Read bodies, all comments, fix/recurrence evidence, and remote default-branch SHAs. Report unresolved/partly fixed/fixed but open/awaiting information/unverified, next steps, and gaps. Distinguish child fix, parent pointer, publication, and installation. Open status does not prove an unfixed bug; access failure is not zero Issues. Use full `owner/repo#number`, including `songloft-org/songloft#number` for parent references.

## Retrospectives

Write evidence-backed task lessons to local Chinese/English LESSONS. Windowed reviews use the parent's ai-review-context.mjs commits for all local histories, explicitly stating remote freshness and gaps. Verify rework, changes that should not have landed, and missing validation; leave unsupported inferences unverified.

Include scope, rule, failure/fix commits, successful example, and Seen dates. Re-reviewing one incident does not increase counts; three independent events on distinct dates make promotion candidates. Mark the authoritative destination and add useful test gates. Existing rules apply immediately and serious failures need not wait three times; lessons cannot expand authorization or reverse product decisions.
