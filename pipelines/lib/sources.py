"""Per-source settings — code as config, reviewed like everything else.

A client on different sources edits DATASETS_RAW in client.env; a source
missing there is skipped by its pipeline. Entity lists here are the Flywheel
defaults and grow as marts need more inputs.
"""

ZOHO = {
    # Zoho CRM REST API. v2 record endpoints return full records without a
    # fields param and honor If-Modified-Since for incremental pulls.
    "api_version": "v2",
    "default_accounts_host": "accounts.zoho.com",  # .eu/.in/... per data center
    "modules": ["Leads", "Contacts", "Accounts", "Deals"],
    "id_field": "id",
    "modified_field": "Modified_Time",
    "page_size": 200,
}

ZOHO_BILLING = {
    # Zoho Billing (formerly Zoho Subscriptions) REST API v1. Same OAuth
    # refresh-token flow as Zoho CRM but a DIFFERENT scope family
    # (ZohoSubscriptions.*), so it gets its own client/refresh-token secrets;
    # the token response's api_domain pins the data center.
    # Every call needs the org header X-com-zoho-subscriptions-organizationid
    # (ZOHO_BILLING_ORG_ID env var).
    # List endpoints paginate with page/per_page and report continuation via
    # page_context.has_more_page; each entity wraps its list under its own
    # plural key and carries its own id field.
    # Full pull every run: the whole subscription book is small (~2k rows),
    # and it keeps cancelled/expired records in sync, which a modified-time
    # incremental would miss.
    "api_path": "billing/v1",
    "org_header": "X-com-zoho-subscriptions-organizationid",
    "entities": [
        {"name": "subscriptions", "path": "subscriptions",
         "list_key": "subscriptions", "id_field": "subscription_id"},
        {"name": "customers", "path": "customers",
         "list_key": "customers", "id_field": "customer_id"},
    ],
    "modified_field": "last_modified_time",
    "page_size": 200,
}

DTOOLS = {
    # D-Tools Cloud API, verified against the live API reference
    # (https://dtcloudapi.d-tools.cloud/apidocs/index.html, linked from
    # https://docs.d-tools.cloud/en/collections/7640732-cloud-api-documentation).
    # Auth is TWO headers: the account's API key in X-API-Key, PLUS a fixed
    # Basic Authorization value that D-Tools publishes verbatim in its public
    # docs ("this is the only one that works") — it is shared across all
    # tenants and is not a secret.
    # Endpoints are RPC-style (/api/v1/<Entity>/Get<Entities>). List
    # endpoints paginate with page/pageSize (server default 20) and wrap the
    # list under an entity-named key ('opportunities', 'projects') plus a
    # total count — hence per-entity list_key. GetQuotes is the exception
    # (verified live): it REQUIRES opportunityId (400 without it, despite the
    # spec marking it optional) and returns a bare array, so quotes are
    # fetched per opportunity id (per_opportunity).
    # Full pull every run (small data volumes); incremental can come later.
    "base_url": "https://dtcloudapi.d-tools.cloud",
    "auth_basic": "Basic RFRDbG91ZEFQSVVzZXI6MyNRdVkrMkR1QCV3Kk15JTU8Yi1aZzlV",
    "entities": [
        {"name": "opportunities", "path": "/api/v1/Opportunities/GetOpportunities",
         "list_key": "opportunities"},
        {"name": "quotes", "path": "/api/v1/Quotes/GetQuotes",
         "per_opportunity": True},
        {"name": "projects", "path": "/api/v1/Projects/GetProjects",
         "list_key": "projects"},
    ],
    "id_field": "id",
    "modified_field": "modifiedDate",
    "page_size": 20,
}

QBO = {
    # QuickBooks Online v3 query API, incremental on MetaData.LastUpdatedTime.
    "base_url": "https://quickbooks.api.intuit.com",
    "token_url": "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer",
    "minorversion": "75",
    "entities": [
        "Customer", "Vendor", "Item", "Account",
        "Estimate", "Invoice", "Bill", "Payment", "PurchaseOrder",
    ],
    "id_field": "Id",
    "modified_field": "MetaData.LastUpdatedTime",
    "page_size": 1000,
}
