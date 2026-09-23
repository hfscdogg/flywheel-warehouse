# goal-cards/ — Phase 4 (pointing the agents at the warehouse)

Each Hermes engine gets a **goal card** instead of a prescriptive prompt:
"your source of truth is the warehouse, here is your credential, here is the
KPI table you are accountable to, and here is how to read it without being
wrong."

One directory per client, one YAML file per card, named for its `kpi`.

| Card | Mart | Status |
|------|------|--------|
| [livewire/sales_won_revenue.yaml](livewire/sales_won_revenue.yaml) | `kpi_sales_pipeline` | active: $400,000 won a month |
| [livewire/cash_ar_over_90.yaml](livewire/cash_ar_over_90.yaml) | `kpi_cash` | active: AR over 90 days at most $25,000 |
| [livewire/subscription_leak.yaml](livewire/subscription_leak.yaml) | `kpi_subscription_audit` | draft, no target |

## Schema

| Key | What it holds |
|-----|---------------|
| `kpi` | Identifier; must equal the file name. |
| `title` | One line a person reads. |
| `status` | `draft` while `target` is null; `active` once the owner sets one. |
| `owner` | Who the engine reports to, and who sets the target. |
| `cadence` | How often it reports. |
| `mart_table` | The one mart the card is accountable to. Never raw, never staging. |
| `credential` | Always `hermes-reader`: read-only, marts and staging, revocable. |
| `definition` | What the number means, in words. |
| `query` | The canonical query. The agent may drill deeper; it reports from this. |
| `columns` | Every mart column the query reads. |
| `baseline` | Where the number stood when the card was written, and as of when. |
| `target` | The owner's. Never filled in by an agent or by whoever drafts the card. |
| `rules` | How to read the number without being wrong. Each one comes from something the data actually did. |
| `drill_down` | Where the agent goes for the rows behind the number. |

`pipelines/tests/test_goal_cards.py` fails if a card is missing a key,
points at a mart that does not exist, lists a column the mart does not
declare, reads anything but its own mart, or is `active` without a target.

## Rules that hold for every card

- The mart's own descriptions are rules too. Call `get_table_schema` before
  reporting; a card rule never overrides one.
- Report the number, the baseline, the target, and the caveats the rules
  name, in that order. A caveat is part of the answer, not a footnote.
- A card is not a licence to act on the rows. Anything that names a customer
  goes to the owner and nobody else unless the owner names them.
