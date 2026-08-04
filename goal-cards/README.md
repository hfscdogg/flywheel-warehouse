# goal-cards/ — Phase 4 (pointing the agents at the warehouse)

Placeholder. Phase 4 hands each Hermes engine a **goal card** instead of a
prescriptive prompt: "your source of truth is the warehouse, here's your
credential, here's the KPI table you're accountable to."

Sketch of the card schema (YAML, one file per card):

```yaml
# kpi: sales_pipeline_velocity
# definition: median days from qualified lead to signed proposal
# mart_table: livewire-dw.marts.kpi_sales_pipeline
# query: SELECT ... (the canonical query; the agent may drill deeper)
# target: "<= 21 days by Q4"
# cadence: weekly
# owner: henry@getlivewire.com
# credential: impersonate hermes-reader@livewire-dw.iam.gserviceaccount.com
```

Access for every card is the same scoped credential: read-only on `marts`
via `hermes-reader` (see [docs/trust.md](../docs/trust.md)).
