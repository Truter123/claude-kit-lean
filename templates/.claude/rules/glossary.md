---
description: Domain terms; they bind every name in code, tests, API and UI. A `not:` word is forbidden.
paths: ["src/**", "adr/**"]
---
<!-- One line per term: term, meaning, not: synonyms. Delete this comment. -->
- `policyholder` (PL: ubezpieczający): concludes the contract and pays the premium. not: client, customer, insured.
- `insured` (PL: ubezpieczony): the person whose interest is covered. not: policyholder.
- `beneficiary` (PL: uposażony): receives the benefit. not: insured.
