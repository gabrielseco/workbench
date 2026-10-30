---
id: invoice-pagination
title: Paginate the contractor invoice list
base: main
budget_usd: 5
turn_timeout_min: 30
status: approved
approved_hash: fb31c2b758a64ab35104ee6f7639367bf1727eb77e723a868fcf4ee3fd2c6819
---

## Request

Paragraph 1: the seed script fails for one country because a call that used to answer 404 now answers 422, and the script must treat both as not found, the way it always treated the 404. Paragraph 2: the seed script fails for one country because a call that used to answer 404 now answers 422, and the script must treat both as not found, the way it always treated the 404. Paragraph 3: the seed script fails for one country because a call that used to answer 404 now answers 422, and the script must treat both as not found, the way it always treated the 404. Paragraph 4: the seed script fails for one country because a call that used to answer 404 now answers 422, and the script must treat both as not found, the way it always treated the 404. Paragraph 5: the seed script fails for one country because a call that used to answer 404 now answers 422, and the script must treat both as not found, the way it always treated the 404. Paragraph 6: the seed script fails for one country because a call that used to answer 404 now answers 422, and the script must treat both as not found, the way it always treated the 404.

## Criteria

- [c1] It works 1.
  - proof: command: pnpm run seed:onboarding --country=CZE --env=sandbox
- [c2] It works 2.
  - proof: test: seed-onboarding/treats a 422 like a 404

## Out of scope

- Everything else.
