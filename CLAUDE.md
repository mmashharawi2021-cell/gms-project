# GMS — Permanent Claude Code Repository Rules

- Read `reference/gms-2.2/GMS_SRS_v2_2_AR.docx`, `README_AR.md`, `QA_Report.md`, SQL scripts and tests before changing architecture. If missing, say so.
- The source SQL 2.2 is a DRAFT, not production migration; PostgreSQL integration NOT yet verified. Audit in empty, isolated DB first.
- Follow `GMS_CLAUDE_CODE_MASTER_PROMPT_AR.md` and `GMS_IMPLEMENTATION_PLAN_AR.md`; update `docs/progress.md` and `docs/requirements-traceability.md` after each milestone.
- Arabic RTL final interfaces and exports. Backend/SQL use explicit schema, Decimal/NUMERIC only for energy and money; reject >2 decimal places for readings.
- Flutter Android must work offline for a full day, store photos and visits durably, unlock by PIN/biometric after initial online login, and sync over Wi-Fi only. Phone must never access PostgreSQL directly.
- Financial statements: final weekly tariff selected by manager; multiple readings per subscriber/week but one final statement, no double bill, append-only ledger, partial payments manager-only.
- Never seed fake production data, silently round readings, delete customer history, overwrite immutable financial rows, claim unexecuted tests passed, or deploy/push/destructively alter data without explicit permission.
- Security authorization must be server-side; users never control DB actor identity directly. Strong negative API tests are mandatory.
- If a prerequisite is unavailable, mark `BLOCKED`, complete independent work, and specify the exact next action.
- Report precise commands/results and continue code implementation phase by phase; don't stop at documentation, mocks, or UI scaffolding.
