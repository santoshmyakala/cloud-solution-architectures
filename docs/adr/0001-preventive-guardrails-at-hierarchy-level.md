# ADR-0001: Enforce baseline controls as preventive guardrails at the hierarchy level

- **Status:** Accepted
- **Context:** Teams need autonomy in their own accounts and subscriptions. Detective-only controls (alerts after the fact) left gaps: public storage, wrong regions, disabled audit logs.
- **Decision:** Unambiguous rules become **deny** policies attached to OUs or management groups (SCPs on AWS, Azure Policy on Azure). Nuanced rules stay detective (Security Hub, Defender for Cloud).
- **Consequences:** Some legitimate edge cases need an exception process (a separate OU or MG, or a policy exemption with an expiry). Policies are code with tests, so changes are reviewed like any other change.
