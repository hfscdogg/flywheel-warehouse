# Access tiers — who can see what in a client's warehouse

Every Flywheel client owns their GCP project outright. Within it, access is
organized as three tiers, from widest to narrowest. Only Tier 1 and the
narrow form of Tier 2 exist today; the rest are recorded here as design
commitments so the answer to "what exactly can Flywheel see?" is written
down before anyone has to ask.

| Tier | Who | Scope | Credential | Status |
|------|-----|-------|-----------|--------|
| 1 | The client's humans | Everything — raw, staging, marts, IAM, billing | `ADMIN_USER` as project owner (console / gcloud) | ✅ live |
| 2a | The client's own agents (narrow) | **`marts` only**, read-only | `hermes-reader` via the hermes-mcp endpoint + bearer token | ✅ live for Livewire (Hermes Agent, 2026-08-25) |
| 2b | The client's own agents (wide) | All datasets (raw + staging + marts), still read-only | A second SA (e.g. `client-agent-reader`) via a second endpoint or scope flag | 📐 design only — built per client on request |
| 3 | Flywheel mothership | A dedicated aggregates dataset only — no row-level data, no PII | A separate per-client SA + token **held by Flywheel**, opt-in | 📐 design only — does not exist |

## Tier 1 — the client's humans

The project owner (`ADMIN_USER` in `clients/<slug>/client.env`) has
unrestricted access through the GCP console and gcloud. This is the only
unfettered access in the system, and it never belongs to an agent.

## Tier 2 — the client's own agents

Agents the client runs for their own benefit (whatever the runtime —
Hermes Agent, Claude, ChatGPT). Two widths, chosen by the client:

- **2a (narrow, the default)**: what [phase-4-hermes-endpoint.md](phase-4-hermes-endpoint.md)
  deploys. The endpoint runs as `hermes-reader`, so the agent reads the
  KPI marts and nothing else — verified from the agent's seat by the two
  scope queries (marts returns rows, raw returns Access Denied).
- **2b (wide)**: for clients who want their agents to drill into raw and
  staging data. Same shape — keyless Cloud Run endpoint, bearer token in
  the client's Secret Manager, one-command revocation — but the runtime SA
  holds dataset-level read on every dataset. Deliberately a *separate*
  service account and endpoint from 2a, so widening one agent never widens
  them all, and `99-teardown.sh` semantics stay clean. Not built until a
  client asks; when one does, it's a variant of `scripts/07-hermes-endpoint.sh`.

Either way, Tier 2 credentials live entirely inside the client's project:
the token in their Secret Manager, the queries in their Cloud Run logs,
revocation in their hands.

## Tier 3 — the Flywheel mothership (community learning)

The recursive-self-improvement loop: Flywheel learning across the whole
client community which KPIs move and what interventions work. Design
commitments, in order of importance:

1. **Off by default.** A client project has no mothership access until the
   client explicitly opts in.
2. **Aggregates only.** The mothership credential reads a dedicated
   dataset (e.g. `benchmarks`) populated by a transform the client can
   inspect — pre-aggregated metrics, no row-level records, no customer
   names, no PII. It never touches `raw_*`, `staging`, or even `marts`.
3. **Separate everything.** Its own service account, its own endpoint or
   query path, its own token — held by Flywheel, revocable by the client
   independently of their own agents' access (Tier 2 keeps working after a
   Tier 3 revoke, and vice versa).
4. **Visible.** The exact tables and columns the mothership can read are
   enumerated in [trust.md](trust.md) when this tier is built, so the
   grant is auditable the same way `hermes-reader`'s is today
   (`bq show --format=prettyjson <project>:benchmarks`).

## The distinction that matters

At client #1 the founder wears both hats, so the tiers can blur in
practice. They must not blur in the architecture: **a client's agents work
for the client; the mothership works for the community; neither borrows
the other's credential.** The narrow Tier 2a credential that exists today
is the client-agent lane — Flywheel-the-company currently holds no
standing access to any client warehouse.
