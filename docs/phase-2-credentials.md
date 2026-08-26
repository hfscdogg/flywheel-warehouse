# Phase 2 — credential setup (human, ~30 minutes)

The three OAuth grants are the only human work in Phase 2. Credential grants
stay with you: every value below goes into **Secret Manager in the client's
own project** — GitHub stores nothing sensitive.

Prerequisites: `./scripts/05-ingestion-infra.sh <slug>` has been run (it
creates the empty secret containers and the WIF plumbing), and you're
authenticated as the project owner.

Load each value like this (paste the value, then Ctrl-D):

```sh
gcloud secrets versions add <secret-name> --project livewire-dw --data-file=-
```

## 1. Zoho CRM (~10 min)

1. Go to the [Zoho API Console](https://api-console.zoho.com/) → **Add
   Client** → **Self Client**.
2. Under **Generate Code**, enter scope
   `ZohoCRM.modules.READ,ZohoCRM.settings.READ`, a description, and generate.
3. Exchange the code for a refresh token (within 10 minutes — the code
   expires):

   ```sh
   curl -s https://accounts.zoho.com/oauth/v2/token \
     -d grant_type=authorization_code \
     -d client_id=<client-id> -d client_secret=<client-secret> \
     -d code=<generated-code>
   ```

4. Load the three values:
   - `flywheel-zoho-client-id`
   - `flywheel-zoho-client-secret`
   - `flywheel-zoho-refresh-token` (the `refresh_token` from step 3)

> Non-US Zoho tenant? Use the matching accounts host (`accounts.zoho.eu`,
> `.in`, …) in step 3 and set `ZOHO_ACCOUNTS_HOST` as an env var on the
> workflow. The pipeline follows the `api_domain` Zoho returns.

## 1b. Zoho Billing (~10 min)

Zoho Billing uses a different OAuth scope family from CRM, so it needs its
own Self Client credentials — the CRM refresh token will not work here.

1. [Zoho API Console](https://api-console.zoho.com/) → **Add Client** →
   **Self Client** (a second one, or reuse the existing client and generate
   a code with the Billing scope).
2. Generate a code with scope
   `ZohoSubscriptions.subscriptions.READ,ZohoSubscriptions.customers.READ`.
3. Exchange it for a refresh token exactly as in step 3 above.
4. Load the three values:
   - `flywheel-zohobilling-client-id`
   - `flywheel-zohobilling-client-secret`
   - `flywheel-zohobilling-refresh-token`
5. Find the **organization id** — Billing → **Settings → Organization
   Profile**, or `GET https://www.zohoapis.com/billing/v1/organizations`
   with the token from step 3. Every API call needs it.
6. Set it as a repo variable (it is an identifier, not a secret):

   ```sh
   gh variable set ZOHO_BILLING_ORG_ID --repo hfscdogg/flywheel-warehouse --body '<org-id>'
   ```

The pipeline pulls the **full** subscription book each run rather than
incrementally: cancelled and expired subscriptions are exactly what the
subscription audit needs, and a modified-time watermark would stop
refreshing rows that stopped changing.

## 2. D-Tools Cloud (~5 min)

1. In D-Tools Cloud: **Settings → Integrations / API** → generate an API key.
2. Load it: `flywheel-dtools-api-key`.

> First live run is a verification run: the endpoint paths in
> `pipelines/lib/sources.py` (`DTOOLS`) are best-effort and must be checked
> against the API reference shown alongside your key. If an endpoint 404s,
> fix the path in `sources.py` — that's the entire change.

## 3. QuickBooks Online (~15 min)

> **Livewire status: live since 2026-08-21.** All four QBO secrets hold
> production values and the daily `ingest-qbo` cron is green. Steps 1–3
> below are done for Livewire — they remain here for the next client.

> **There is no approval notice to wait for.** This trips people up, so it
> is worth stating plainly. Intuit's "Application Assessment Questionnaire
> Completed" email *is* the completion notice — it says "no further action
> is required at this time." Production keys unblock once the questionnaire
> is submitted **and** the Production Settings tab is complete (host domain,
> launch URL, disconnect URL, hosting country/IP, regulated industries).
> Intuit never emails an approval. A successful App Center connection to a
> real company is the proof that production keys are live. Separate App
> Store *listing* review applies only to publicly published apps — an
> internal ingestion app never enters it.
>
> Two failure modes to know about, both seen on this app:
>
> - **Waiting for an approval that will never arrive.** Check the portal
>   instead: My Apps → *app* → Production Settings → App assessment
>   questionnaire should read *Submission status: Completed*, and Keys &
>   credentials should show the production client ID and secret.
> - **Loading development keys and getting a 403 from the data API.** A
>   sandbox refresh token refreshes cleanly against
>   `oauth.platform.intuit.com` and then fails with `403` against the
>   production host `quickbooks.api.intuit.com`, because sandbox traffic
>   must go to `sandbox-quickbooks.api.intuit.com`. If token refresh
>   succeeds but every query 403s, the loaded keys are the wrong pair.
>   Livewire lost two weeks of nightly runs to exactly this.

1. At [developer.intuit.com](https://developer.intuit.com/): create (or open)
   an app with the **Accounting** scope (`com.intuit.quickbooks.accounting`);
   note the **production** client ID and secret.
2. Use the [OAuth 2.0 Playground](https://developer.intuit.com/app/developer/playground)
   to authorize against the live Livewire company — this is the consent
   click — and capture the **refresh token** and **realm ID**.
3. Load the four values:
   - `flywheel-qbo-client-id`
   - `flywheel-qbo-client-secret`
   - `flywheel-qbo-refresh-token`
   - `flywheel-qbo-realm-id`

> **Rotation is handled.** QBO invalidates and replaces refresh tokens over
> time; the pipeline writes each new token back to Secret Manager
> automatically (that's why `ingest-writer` holds `secretVersionAdder` on
> that one secret). Never paste the refresh token anywhere else — a stale
> copy stops working.

## 4. GitHub repo variables (one-time, not sensitive)

`05-ingestion-infra.sh` prints the exact commands; they identify which GCP
identity the workflows federate into:

```sh
gh variable set WIF_PROVIDER --repo hfscdogg/flywheel-warehouse --body '<provider resource name>'
gh variable set WIF_SERVICE_ACCOUNT --repo hfscdogg/flywheel-warehouse --body 'ingest-writer@livewire-dw.iam.gserviceaccount.com'
```

## 5. Smoke run

Trigger each workflow manually (Actions tab → `ingest-zoho` /
`ingest-zohobilling` / `ingest-dtools` / `ingest-qbo` → **Run workflow**). Then confirm rows landed:

```sh
bq query --use_legacy_sql=false \
  'SELECT _run_id, COUNT(*) n, MAX(_loaded_at) latest
   FROM `livewire-dw.raw_zoho.deals` GROUP BY 1 ORDER BY latest DESC LIMIT 3'
```

After that, the daily crons (06:00 / 06:20 / 06:40 UTC) take over.
