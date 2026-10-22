# Changelog

## 3.0.0 — LenDen v3

Built from the *LenDen v3 Architecture* document: three phases, all shipped.

### Phase 1 — borrower experience
- 4-step wizard (quick check in steps 1–2), autosaved as a **draft** on the server; works without an
  account (anonymous draft token) and is claimed on sign-up or login.
- **Approval odds** (excellent / good / fair / low) relative to each lender's own threshold.
- **Live simulator** (`POST /v1/simulate`) and the **smallest change** that lifts the odds one level
  (counterfactual over amount, term, co-signer, debt, rate; up to three changes).
- **Offer estimates** from every active lender (`GET /v1/drafts/{id}/offers`): amount and rate range,
  best combination, instalment and affordability.
- Status **timeline**, in-app **notifications** with an outbox for email/SMS, Bangla/English app.
- API under **`/v1`** (v2 paths kept), error codes, request ids, idempotency keys.

### Phase 2 — marketplace and trust
- Per-lender **offer rules** (rates, limits, terms, policy limits, ladder caps) with validation.
- Apply with an offer; officers **claim/release**, see SLA timers, request **documents**; borrowers
  upload PDF/JPG/PNG (type sniffing, 5 MB) and download through 5-minute signed links.
- Declines require **reason codes**; borrowers see plain-language reasons and what would help.
- **Model registry** with candidate → shadow → active, live shadow scores and an offline comparison.
- Refresh tokens with rotation and reuse detection, login lockout, password reset, TOTP for staff.

### Phase 3 — Bangladesh-ready credit
- Loans with **repayment schedules**, (mock) payments, late/missed tracking and arrears.
- **Credit ladder** L1–L4 (10/25/50/100% of a lender's maximum), promotion on on-time repayment,
  demotion after a payment missed by 30 days.
- Mobile number verification and **OTP login** (SMS mocked), Taka formatting with Bangla digits.
- Portfolio view, fairness report by optional self-reported groups, officer override statistics,
  daily drift snapshots, consents (view/revoke), data export and account deletion.

### Model
- New platform model **`lenden-v3`** trained without age, marital status and dependants. v2 failed the
  4/5ths rule for marital status (0.76) and dependants (0.62); v3's worst ratio is 0.94, with test
  AUC 0.706 and 63.8% savings (v2: 0.710, 64.0%).

### Engineering
- Domain modules (`src/lenden/domain`), versioned SQL migrations for SQLite and PostgreSQL, a
  connection pool with per-request transactions, append-only history, background jobs with
  PostgreSQL advisory locks, nightly backup workflow, 85 backend tests on both databases.
