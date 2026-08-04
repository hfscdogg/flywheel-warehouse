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

DTOOLS = {
    # D-Tools Cloud REST API (X-API-Key auth). VERIFY on first live run:
    # endpoint paths and pagination params below are best-effort from docs
    # and must be confirmed against the account's API reference — the
    # fetcher is generic (path + list pagination), so fixing an entry here
    # is the whole change. Full pull every run (small data volumes);
    # incremental can come later if volumes ever warrant it.
    "base_url": "https://api.dtools.cloud",
    "entities": [
        {"name": "opportunities", "path": "/api/v1/opportunities"},
        {"name": "quotes", "path": "/api/v1/quotes"},
        {"name": "projects", "path": "/api/v1/projects"},
    ],
    "id_field": "id",
    "modified_field": "updatedDate",
    "page_size": 100,
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
