<!-- No `paths:` frontmatter: this file loads every session, so keep it to one line per rule.
Rule 5: one rules file, one line per rule (BR-NNN, rule, reason, source). Never a digest beside a catalogue.
Rule 1: a rule lives only here; code, ADRs and docs point to its BR id. Delete this comment. -->
# Business rules

- BR-001 Cover starts at the earliest on the day after the first premium is paid. Why: no cover on unpaid risk. Source: general terms §5.
- BR-002 A cancelled policy is never deleted; status is set to CANCELLED. Why: audit and claims after cancellation. Source: ADR 0001.
- BR-003 Premium is rounded to 2 decimals, half up, in PLN. Why: matches the insurer's invoices. Source: client decision.

<!-- Dates and money, write down once: time zone, whether the end of the cover period is inclusive,
premium rounding, currency. Most bugs in insurance CRUD live there. -->
