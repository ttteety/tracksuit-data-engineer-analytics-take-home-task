# Subscriptions Dimensional Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the dbt project from the approved spec (`docs/superpowers/specs/2026-06-04-subscriptions-dimensional-model-design.md`): staging → intermediate → marts (dim_customers, dim_subscriptions, fct_subscription_months) → rpt_grr_by_size_segment, fully tested and documented.

**Architecture:** Monthly-snapshot fact at subscription × active-month grain, fed by a bounded month spine; account-grain customer dimension with HubSpot enrichment via a merge-resolution map; sparse GRR report anchored on the data horizon. Surrogate keys are generated in marts (per CLAUDE.md). Revenue is invoiced truth, never imputed (ADR 0001).

**Tech Stack:** dbt-duckdb ~1.9, DuckDB ~1.1, dbt_utils. Windows/PowerShell; venv at `.venv`.

> **⚠ COMMITS ARE MANUAL.** Per CLAUDE.md ("The git will manually commit"), the executor NEVER runs `git commit`. Each task ends with a **checkpoint** step: stop, tell the user the task is done, and suggest a commit message. Wait for the user before continuing only if they say so; otherwise proceed after notifying.

**Conventions used by every verification step:**

- Run dbt (PowerShell): `.\.venv\Scripts\dbt.exe <args>` (no venv activation needed)
- Query DuckDB: **use the Bash tool**, not PowerShell — PowerShell 5.1 strips embedded double quotes when passing args to native exes, so `python -c '...'` one-liners break there. In bash:
  `./.venv/Scripts/python.exe -c 'import duckdb; print(duckdb.connect("tracksuit.duckdb", read_only=True).sql("<SQL>").fetchall())'`
  If a query needs single quotes inside the SQL (string literals), write it to a temp `_verify.py` file instead, run it, then delete it.
- dbt models land in the `analytics` schema of `tracksuit.duckdb`.
- If `tracksuit.duckdb` is missing, run `.\.venv\Scripts\python.exe load_raw_data.py` first.

---

### Task 1: Project scaffolding — .gitignore, packages, materialization config, sources

**Files:**
- Create: `.gitignore`
- Create: `packages.yml`
- Modify: `dbt_project.yml` (models block only)
- Create: `models/staging/_staging__sources.yml`

- [ ] **Step 1: Create `.gitignore`**

```gitignore
# local artifacts — reviewers regenerate these via load_raw_data.py + dbt build
tracksuit.duckdb
target/
dbt_packages/
logs/
.venv/
.user.yml
.DS_Store
```

- [ ] **Step 2: Create `packages.yml`**

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.1.0", "<2.0.0"]
```

- [ ] **Step 3: Configure marts as tables in `dbt_project.yml`**

Replace the existing `models:` block (last 3 lines of the file) with:

```yaml
# Staging stays as views (project default — thin 1:1 typed mappings). Intermediate
# and marts are tables: intermediate holds the month spine the fact builds on, and
# marts are the queried-by-humans layer; everything rebuilds cheaply at this scale.
models:
  tracksuit_take_home:
    +materialized: view
    intermediate:
      +materialized: table
    marts:
      +materialized: table
```

> Note (user decision during execution): intermediate is materialized as **table**, not view. Task 3/4 "Expected" lines saying "view created" should read "table created".

- [ ] **Step 4: Declare sources in `models/staging/_staging__sources.yml`**

```yaml
version: 2

sources:
  - name: hubspot
    description: CRM company records, landed as-is (all VARCHAR) by load_raw_data.py.
    schema: raw
    tables:
      - name: hubspot_companies
        description: One row per HubSpot company. merged_object_ids holds semicolon-separated old company IDs merged into this record.

  - name: subskribe
    description: Billing system (accounts, subscriptions, invoices), landed as-is (all VARCHAR) by load_raw_data.py.
    schema: raw
    tables:
      - name: subskribe_accounts
        description: One row per billing account. crmid references a HubSpot company_id — possibly a merged-away one.
      - name: subskribe_subscriptions
        description: One row per subscription term. Renewals are new rows linked via renewed_from_subscription_id.
      - name: subskribe_invoices
        description: One row per issued invoice. Monthly cadence, billed on days 1–7. total_nzd is the NZD-converted amount.
```

- [ ] **Step 5: Install packages and verify the project parses**

Run: `.\.venv\Scripts\dbt.exe deps`
Expected: `Installed from version ...` for dbt_utils, exit 0.

Run: `.\.venv\Scripts\dbt.exe parse`
Expected: `Performance info: ...` and exit 0 — no parse errors.

- [ ] **Step 6: Checkpoint — manual commit (user)**

Suggested message: `chore: scaffold dbt project — gitignore, dbt_utils, marts-as-tables, source declarations`

---

### Task 2: Staging layer — four 1:1 source views

**Files:**
- Create: `models/staging/stg_hubspot__companies.sql`
- Create: `models/staging/stg_subskribe__accounts.sql`
- Create: `models/staging/stg_subskribe__subscriptions.sql`
- Create: `models/staging/stg_subskribe__invoices.sql`
- Create: `models/staging/_staging__models.yml`

Staging rules (CLAUDE.md): 1:1 with source, snake_case renames, type casting, **no derived columns, no surrogate keys**.

- [ ] **Step 1: Create `models/staging/stg_hubspot__companies.sql`**

```sql
with source as (

    select * from {{ source('hubspot', 'hubspot_companies') }}

),

renamed as (

    select
        company_id,
        company_name,
        size_grouped,
        industry,
        country,
        merged_object_ids,
        cast(created_at as date) as created_at

    from source

)

select * from renamed
```

- [ ] **Step 2: Create `models/staging/stg_subskribe__accounts.sql`**

```sql
with source as (

    select * from {{ source('subskribe', 'subskribe_accounts') }}

),

renamed as (

    select
        account_id,
        company_name as account_name,
        crmid as crm_company_id,
        currency as billing_currency,
        cast(created_at as date) as created_at

    from source

)

select * from renamed
```

- [ ] **Step 3: Create `models/staging/stg_subskribe__subscriptions.sql`**

```sql
with source as (

    select * from {{ source('subskribe', 'subskribe_subscriptions') }}

),

renamed as (

    select
        subscription_id,
        account_id,
        subscription_state,
        cast(start_date as date) as start_date,
        cast(end_date as date) as end_date,
        cast(cancelled_date as date) as cancelled_date,
        renewed_from_subscription_id,
        cast(creation_time as timestamp) as created_at,
        cast(updated_at as timestamp) as updated_at

    from source

)

select * from renamed
```

- [ ] **Step 4: Create `models/staging/stg_subskribe__invoices.sql`**

```sql
with source as (

    select * from {{ source('subskribe', 'subskribe_invoices') }}

),

renamed as (

    select
        invoice_id,
        account_id,
        subscription_id,
        cast(invoice_date as date) as invoice_date,
        cast(total as decimal(18, 2)) as total_amount,
        cast(total_nzd as decimal(18, 2)) as total_nzd,
        currency,
        status

    from source

)

select * from renamed
```

- [ ] **Step 5: Create `models/staging/_staging__models.yml`**

```yaml
version: 2

models:
  - name: stg_hubspot__companies
    description: >
      HubSpot company records, 1:1 with raw.hubspot_companies. Typed and renamed only.
      14 rows carry merged_object_ids — semicolon-separated old company IDs merged into
      the surviving record; int_company_id_map explodes these for CRM-link resolution.
    columns:
      - name: company_id
        description: Unique HubSpot company id (PK).
        tests:
          - unique
          - not_null
      - name: company_name
        description: Company display name in HubSpot.
      - name: size_grouped
        description: Customer size segment assigned in the CRM.
        tests:
          - accepted_values:
              values: ['Enterprise', 'Mid-Market', 'SMB', 'Startup']
      - name: industry
        description: Industry classification.
      - name: country
        description: HQ country code.
      - name: merged_object_ids
        description: Semicolon-separated old HubSpot company IDs merged into this record. NULL when no merges happened.
      - name: created_at
        description: Date the company record was created in HubSpot.

  - name: stg_subskribe__accounts
    description: >
      Subskribe billing accounts, 1:1 with raw.subskribe_accounts. The account is the
      paying entity and becomes the grain of dim_customers.
    columns:
      - name: account_id
        description: Unique Subskribe account id (PK).
        tests:
          - unique
          - not_null
      - name: account_name
        description: Billing account display name. Often but not always matches the HubSpot company name — crm_company_id is the link, not the name.
      - name: crm_company_id
        description: >
          Reference to a HubSpot company_id. May point at a merged-away (hsold_*) or
          missing (hsmissing_*) id — resolution happens in int_company_id_map.
        tests:
          - not_null
      - name: billing_currency
        description: Account billing currency (NZD/USD/GBP/AUD).
      - name: created_at
        description: Date the account was created in Subskribe.

  - name: stg_subskribe__subscriptions
    description: >
      Subscription terms, 1:1 with raw.subskribe_subscriptions. Renewals create a new
      row linked to the predecessor via renewed_from_subscription_id; chains never
      overlap in dates.
    columns:
      - name: subscription_id
        description: Unique subscription id (PK).
        tests:
          - unique
          - not_null
      - name: account_id
        description: Owning billing account.
        tests:
          - not_null
          - relationships:
              to: ref('stg_subskribe__accounts')
              field: account_id
      - name: subscription_state
        description: Current lifecycle state of the subscription (point-in-time as of the data extract).
        tests:
          - accepted_values:
              values: ['ACTIVE', 'CANCELED', 'EXPIRED']
      - name: start_date
        description: Subscription term start.
        tests:
          - not_null
      - name: end_date
        description: Subscription term end (actual or scheduled).
        tests:
          - not_null
      - name: cancelled_date
        description: Cancellation date when state is CANCELED; NULL otherwise. No invoices exist after this date.
      - name: renewed_from_subscription_id
        description: Predecessor subscription when this row is a renewal; NULL for first terms.
      - name: created_at
        description: Source row creation timestamp.
      - name: updated_at
        description: Source row last-modified timestamp.

  - name: stg_subskribe__invoices
    description: >
      Issued invoices, 1:1 with raw.subskribe_invoices. Cleanly monthly — at most one
      invoice per subscription per calendar month, billed on days 1–7. VOIDED invoices
      were never re-issued.
    columns:
      - name: invoice_id
        description: Unique invoice id (PK).
        tests:
          - unique
          - not_null
      - name: account_id
        description: Billed account.
        tests:
          - not_null
          - relationships:
              to: ref('stg_subskribe__accounts')
              field: account_id
      - name: subscription_id
        description: Billed subscription.
        tests:
          - not_null
          - relationships:
              to: ref('stg_subskribe__subscriptions')
              field: subscription_id
      - name: invoice_date
        description: Issue date. Can precede the subscription start_date by up to 29 days (advance billing) but never falls in an earlier calendar month.
        tests:
          - not_null
      - name: total_amount
        description: Invoice amount in the account's billing currency.
      - name: total_nzd
        description: Invoice amount converted to NZD (Tracksuit's functional currency). The only amount used downstream.
        tests:
          - not_null
      - name: currency
        description: Invoice currency code.
      - name: status
        description: Invoice lifecycle status. Revenue downstream counts PAID + POSTED; VOIDED is excluded.
        tests:
          - accepted_values:
              values: ['PAID', 'POSTED', 'VOIDED']
```

- [ ] **Step 6: Build staging and run its tests**

Run: `.\.venv\Scripts\dbt.exe build --select staging`
Expected: 4 views created, all tests PASS, exit 0.

- [ ] **Step 7: Verify row counts match raw**

Run (Bash tool): `./.venv/Scripts/python.exe -c 'import duckdb; c=duckdb.connect("tracksuit.duckdb", read_only=True); print([c.sql("SELECT count(*) FROM analytics." + t).fetchone()[0] for t in ["stg_hubspot__companies","stg_subskribe__accounts","stg_subskribe__subscriptions","stg_subskribe__invoices"]])'`
Expected: `[120, 122, 330, 3594]`

- [ ] **Step 8: Checkpoint — manual commit (user)**

Suggested message: `feat: staging layer — typed 1:1 views over the four raw sources, with PK/FK/accepted-values tests`

---

### Task 3: int_company_id_map — CRM merge resolution

**Files:**
- Create: `models/intermediate/int_company_id_map.sql`
- Create: `models/intermediate/_intermediate__models.yml`

- [ ] **Step 1: Create `models/intermediate/int_company_id_map.sql`**

```sql
-- Maps every HubSpot company id an account might reference — live or merged-away —
-- to the surviving company record. Verified: no old id appears under two survivors,
-- and no old id collides with a live id, so this map cannot fan out.

with companies as (

    select * from {{ ref('stg_hubspot__companies') }}

),

live_ids as (

    select
        company_id as crm_company_id,
        company_id
    from companies

),

merged_ids_exploded as (

    select
        unnest(string_split(merged_object_ids, ';')) as crm_company_id,
        company_id
    from companies
    where merged_object_ids is not null

),

merged_ids as (

    select
        trim(crm_company_id) as crm_company_id,
        company_id
    from merged_ids_exploded

)

select * from live_ids
union all
select * from merged_ids
```

- [ ] **Step 2: Create `models/intermediate/_intermediate__models.yml`** (covers both intermediate models; the int_subscription_months entry is added in Task 4 — for now include only int_company_id_map)

```yaml
version: 2

models:
  - name: int_company_id_map
    description: >
      Lookup from any HubSpot company id an account might reference (live, or
      merged-away via merged_object_ids) to the surviving company_id. 139 rows =
      120 live ids + 19 exploded merged ids. Accounts whose crm_company_id is
      absent from this map (the hsmissing_* ids) are genuinely unmatchable.
    columns:
      - name: crm_company_id
        description: A HubSpot company id as it may appear in subskribe_accounts.crmid (PK).
        tests:
          - unique
          - not_null
      - name: company_id
        description: The surviving HubSpot company record this id resolves to.
        tests:
          - not_null
          - relationships:
              to: ref('stg_hubspot__companies')
              field: company_id
```

- [ ] **Step 3: Build and test**

Run: `.\.venv\Scripts\dbt.exe build --select int_company_id_map`
Expected: 1 view created, 4 tests PASS, exit 0.

- [ ] **Step 4: Verify row count and resolution coverage**

Run (Bash tool): `./.venv/Scripts/python.exe -c 'import duckdb; c=duckdb.connect("tracksuit.duckdb", read_only=True); print(c.sql("SELECT count(*) FROM analytics.int_company_id_map").fetchone()); print(c.sql("SELECT count(*) FROM analytics.stg_subskribe__accounts a LEFT JOIN analytics.int_company_id_map m ON a.crm_company_id = m.crm_company_id WHERE m.company_id IS NULL").fetchone())'`
Expected: `(139,)` then `(2,)` — 139 map rows; exactly the 2 hsmissing_* accounts unresolved.

- [ ] **Step 5: Checkpoint — manual commit (user)**

Suggested message: `feat: int_company_id_map — resolve merged-away HubSpot ids to surviving companies`

---

### Task 4: int_subscription_months — bounded month spine + invoice aggregates

**Files:**
- Create: `models/intermediate/int_subscription_months.sql`
- Modify: `models/intermediate/_intermediate__models.yml` (append second model entry)

- [ ] **Step 1: Create `models/intermediate/int_subscription_months.sql`**

```sql
-- One row per subscription per active calendar month. The spine runs from the start
-- month to the earliest of: end month, cancelled month, data horizon (latest invoice
-- month — complete, since all billing happens on days 1-7). Verified: this spine has
-- exactly 113 zero-revenue months, all explained by VOIDED invoices, and drops no
-- non-voided invoice (enforced downstream by a reconciliation test on the fact).
-- Revenue is invoiced truth, never imputed — see docs/adr/0001.

with subscriptions as (

    select * from {{ ref('stg_subskribe__subscriptions') }}

),

invoices as (

    select * from {{ ref('stg_subskribe__invoices') }}

),

data_horizon as (

    select date_trunc('month', max(invoice_date)) as horizon_month
    from invoices

),

month_spine as (

    select
        s.subscription_id,
        s.account_id,
        cast(gs.generate_series as date) as month_start_date
    from subscriptions as s
    cross join data_horizon as h
    cross join generate_series(
        date_trunc('month', s.start_date),
        least(
            date_trunc('month', s.end_date),
            date_trunc('month', coalesce(s.cancelled_date, s.end_date)),
            h.horizon_month
        ),
        interval 1 month
    ) as gs

),

invoice_months as (

    select
        subscription_id,
        cast(date_trunc('month', invoice_date) as date) as month_start_date,
        sum(total_nzd) filter (where status != 'VOIDED') as revenue_nzd,
        count(*) filter (where status != 'VOIDED') as invoice_count,
        count(*) filter (where status = 'VOIDED') as voided_invoice_count
    from invoices
    group by 1, 2

)

select
    month_spine.subscription_id,
    month_spine.account_id,
    month_spine.month_start_date,
    coalesce(invoice_months.revenue_nzd, 0) as revenue_nzd,
    coalesce(invoice_months.invoice_count, 0) as invoice_count,
    coalesce(invoice_months.voided_invoice_count, 0) as voided_invoice_count
from month_spine
left join invoice_months
    on month_spine.subscription_id = invoice_months.subscription_id
    and month_spine.month_start_date = invoice_months.month_start_date
```

- [ ] **Step 2: Append to `models/intermediate/_intermediate__models.yml`** (add this entry under the existing `models:` list, after int_company_id_map)

```yaml
  - name: int_subscription_months
    description: >
      Bounded month spine per subscription with monthly invoice aggregates. Grain:
      subscription x active calendar month (3,594 rows). Active = start month through
      the earliest of end month, cancelled month, and the data horizon. revenue_nzd is
      non-voided (PAID + POSTED) invoiced NZD only — voided-only months show 0 revenue
      with voided_invoice_count = 1 (see ADR 0001).
    columns:
      - name: subscription_id
        description: Subscription this month belongs to.
        tests:
          - not_null
      - name: account_id
        description: Owning account, carried through for the fact's customer key.
        tests:
          - not_null
      - name: month_start_date
        description: First day of the active calendar month.
        tests:
          - not_null
      - name: revenue_nzd
        description: Non-voided invoiced NZD in this month. 0 for voided-only months.
        tests:
          - not_null
      - name: invoice_count
        description: Count of non-voided invoices this month (0 or 1 in practice).
      - name: voided_invoice_count
        description: Count of voided invoices this month (0 or 1 in practice).
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - subscription_id
            - month_start_date
```

- [ ] **Step 3: Build and test**

Run: `.\.venv\Scripts\dbt.exe build --select int_subscription_months`
Expected: 1 view created, 5 tests PASS, exit 0.

- [ ] **Step 4: Verify spine shape — row count, zero-revenue months, voided explanation**

Run (Bash tool): `./.venv/Scripts/python.exe -c 'import duckdb; c=duckdb.connect("tracksuit.duckdb", read_only=True); print(c.sql("SELECT count(*), count(*) FILTER (WHERE revenue_nzd = 0), count(*) FILTER (WHERE revenue_nzd = 0 AND voided_invoice_count > 0), min(month_start_date), max(month_start_date) FROM analytics.int_subscription_months").fetchall())'`
Expected: `[(3594, 113, 113, datetime.date(2023, 6, 1), datetime.date(2026, 5, 1))]` — 3,594 spine rows; 113 zero-revenue months, all voided-explained; spine spans Jun 2023 → May 2026.

- [ ] **Step 5: Checkpoint — manual commit (user)**

Suggested message: `feat: int_subscription_months — bounded month spine with monthly invoice aggregates`

---

### Task 5: Dimensions — dim_customers and dim_subscriptions

**Files:**
- Create: `models/marts/core/dim_customers.sql`
- Create: `models/marts/core/dim_subscriptions.sql`
- Create: `models/marts/core/_core__models.yml` (fact entry appended in Task 6)

- [ ] **Step 1: Create `models/marts/core/dim_customers.sql`**

```sql
-- Customer = the paying entity: a Subskribe billing account enriched with HubSpot
-- attributes. Grain: account (122 rows). The 2 accounts whose crm id is genuinely
-- unmatchable stay in the dim with size_grouped = 'Unknown' — revenue is never
-- silently dropped, and crm_match_status makes the data quality story queryable.

with accounts as (

    select * from {{ ref('stg_subskribe__accounts') }}

),

companies as (

    select * from {{ ref('stg_hubspot__companies') }}

),

id_map as (

    select * from {{ ref('int_company_id_map') }}

),

resolved as (

    select
        accounts.account_id,
        accounts.account_name,
        accounts.billing_currency,
        accounts.created_at as account_created_at,
        accounts.crm_company_id,
        id_map.company_id
    from accounts
    left join id_map
        on accounts.crm_company_id = id_map.crm_company_id

)

select
    {{ dbt_utils.generate_surrogate_key(['resolved.account_id']) }} as customer_key,
    resolved.account_id,
    resolved.company_id,
    coalesce(companies.company_name, resolved.account_name) as customer_name,
    resolved.account_name,
    coalesce(companies.size_grouped, 'Unknown') as size_grouped,
    companies.industry,
    companies.country,
    resolved.billing_currency,
    case
        when resolved.company_id is null then 'unmatched'
        when resolved.company_id = resolved.crm_company_id then 'matched'
        else 'merged_resolved'
    end as crm_match_status,
    resolved.account_created_at,
    companies.created_at as company_created_at
from resolved
left join companies
    on resolved.company_id = companies.company_id
```

- [ ] **Step 2: Create `models/marts/core/dim_subscriptions.sql`**

```sql
-- Subscription dimension: static attributes and renewal lineage. Grain: subscription
-- (330 rows). Renewals are new subscription rows chained via
-- renewed_from_subscription_id; the chain never overlaps in dates. The customer_key
-- hash matches dim_customers by construction (same surrogate-key input).

with subscriptions as (

    select * from {{ ref('stg_subskribe__subscriptions') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['subscription_id']) }} as subscription_key,
    subscription_id,
    {{ dbt_utils.generate_surrogate_key(['account_id']) }} as customer_key,
    account_id,
    subscription_state,
    start_date,
    end_date,
    cancelled_date,
    renewed_from_subscription_id,
    renewed_from_subscription_id is not null as is_renewal
from subscriptions
```

- [ ] **Step 3: Create `models/marts/core/_core__models.yml`**

```yaml
version: 2

models:
  - name: dim_customers
    description: >
      The paying entity — a Subskribe billing account enriched with HubSpot company
      attributes. Grain: one row per account (122 rows). CRM links are resolved
      through int_company_id_map so merged-away HubSpot ids land on the surviving
      company; the 2 genuinely unmatchable accounts carry size_grouped = 'Unknown'
      and crm_match_status = 'unmatched'. Customer identity is the GRR cohort
      identity: it persists across subscription renewals.
    columns:
      - name: customer_key
        description: Surrogate key from account_id (PK).
        tests:
          - unique
          - not_null
      - name: account_id
        description: Natural key — the Subskribe account id.
        tests:
          - unique
          - not_null
      - name: company_id
        description: Resolved HubSpot company id. NULL for the 2 unmatched accounts.
      - name: customer_name
        description: HubSpot company name, falling back to the billing account name when unmatched.
        tests:
          - not_null
      - name: account_name
        description: Subskribe billing account name (kept alongside for reconciliation against the CRM name).
      - name: size_grouped
        description: >
          Customer size segment. 'Unknown' = the CRM link is unresolvable, so size is
          genuinely unknowable; these rows appear in GRR output where they have cohort
          revenue, as an actionable data quality flag.
        tests:
          - not_null
          - accepted_values:
              values: ['Enterprise', 'Mid-Market', 'SMB', 'Startup', 'Unknown']
      - name: industry
        description: HubSpot industry classification. NULL when unmatched.
      - name: country
        description: HubSpot HQ country. NULL when unmatched.
      - name: billing_currency
        description: Account billing currency. Revenue measures are always NZD regardless.
      - name: crm_match_status
        description: >
          How the CRM link resolved — 'matched' (crmid is a live company id),
          'merged_resolved' (crmid pointed at a merged-away id, resolved via
          merged_object_ids), or 'unmatched' (hsmissing_* id, no company record).
        tests:
          - not_null
          - accepted_values:
              values: ['matched', 'merged_resolved', 'unmatched']
      - name: account_created_at
        description: Date the billing account was created in Subskribe.
      - name: company_created_at
        description: Date the company record was created in HubSpot. NULL when unmatched.

  - name: dim_subscriptions
    description: >
      Subscription terms with static attributes and renewal lineage. Grain: one row
      per subscription (330 rows). subscription_state is the current state as of the
      data extract; point-in-time state for any month is derivable from
      start_date / end_date / cancelled_date. Renewal chains never overlap in dates.
    columns:
      - name: subscription_key
        description: Surrogate key from subscription_id (PK).
        tests:
          - unique
          - not_null
      - name: subscription_id
        description: Natural key — the Subskribe subscription id.
        tests:
          - unique
          - not_null
      - name: customer_key
        description: Owning customer.
        tests:
          - not_null
          - relationships:
              to: ref('dim_customers')
              field: customer_key
      - name: account_id
        description: Natural key of the owning account, for source traceability.
      - name: subscription_state
        description: Current lifecycle state (ACTIVE / CANCELED / EXPIRED) as of the extract.
        tests:
          - accepted_values:
              values: ['ACTIVE', 'CANCELED', 'EXPIRED']
      - name: start_date
        description: Term start date.
        tests:
          - not_null
      - name: end_date
        description: Term end date (actual or scheduled).
        tests:
          - not_null
      - name: cancelled_date
        description: Cancellation date when CANCELED; NULL otherwise. Billing stops after this date.
      - name: renewed_from_subscription_id
        description: Predecessor subscription id when this term is a renewal.
      - name: is_renewal
        description: True when this subscription renewed a previous term.
        tests:
          - not_null
```

- [ ] **Step 4: Build and test both dimensions**

Run: `.\.venv\Scripts\dbt.exe build --select dim_customers dim_subscriptions`
Expected: 2 tables created, all tests PASS, exit 0.

- [ ] **Step 5: Verify dimension contents**

Run (Bash tool): `./.venv/Scripts/python.exe -c 'import duckdb; c=duckdb.connect("tracksuit.duckdb", read_only=True); print(c.sql("SELECT crm_match_status, count(*) FROM analytics.dim_customers GROUP BY 1 ORDER BY 2 DESC").fetchall()); print(c.sql("SELECT size_grouped, count(*) FROM analytics.dim_customers GROUP BY 1 ORDER BY 2 DESC").fetchall()); print(c.sql("SELECT count(*), count(*) FILTER (WHERE is_renewal) FROM analytics.dim_subscriptions").fetchall())'`
Expected:
- crm_match_status: `[('matched', 109), ('merged_resolved', 11), ('unmatched', 2)]`
- size_grouped: SMB 43, Mid-Market 41, Startup 25, Enterprise 11, Unknown 2 (order may vary)
- dim_subscriptions: `[(330, 208)]` — 330 subs, 208 renewals (verified against raw: 208 rows have a predecessor; all 122 accounts have subscriptions)

- [ ] **Step 6: Checkpoint — manual commit (user)**

Suggested message: `feat: dim_customers and dim_subscriptions — account-grain customer with CRM merge resolution, subscription dim with renewal lineage`

---

### Task 6: fct_subscription_months + revenue reconciliation test

**Files:**
- Create: `models/marts/core/fct_subscription_months.sql`
- Modify: `models/marts/core/_core__models.yml` (append fact entry)
- Create: `tests/assert_fct_revenue_reconciles_to_invoices.sql`

- [ ] **Step 1: Create `models/marts/core/fct_subscription_months.sql`**

```sql
-- Monthly snapshot fact. Grain: subscription x active calendar month (3,594 rows).
-- Row existence answers "was this subscription active in month M" — no date-range
-- logic needed by consumers. revenue_nzd reconciles exactly to non-voided source
-- invoices (enforced by tests/assert_fct_revenue_reconciles_to_invoices.sql).

with subscription_months as (

    select * from {{ ref('int_subscription_months') }}

)

select
    {{ dbt_utils.generate_surrogate_key(['subscription_id', 'month_start_date']) }} as subscription_month_key,
    month_start_date,
    {{ dbt_utils.generate_surrogate_key(['subscription_id']) }} as subscription_key,
    {{ dbt_utils.generate_surrogate_key(['account_id']) }} as customer_key,
    revenue_nzd,
    invoice_count,
    voided_invoice_count
from subscription_months
```

- [ ] **Step 2: Append the fact entry to `models/marts/core/_core__models.yml`** (under the existing `models:` list)

```yaml
  - name: fct_subscription_months
    description: >
      Monthly snapshot fact of subscriptions over time. Grain: one row per
      subscription per active calendar month (3,594 rows, Jun 2023 - May 2026).
      A subscription was active in month M if and only if a row exists for it —
      "subscriptions as of any given month" is a simple equality filter. Revenue is
      invoiced truth (PAID + POSTED, NZD), never imputed: the 113 voided-only months
      show revenue_nzd = 0 with voided_invoice_count = 1 (see ADR 0001). Renewal
      boundary months legitimately hold two rows for one customer (old term's last
      bill + new term's first bill).
    columns:
      - name: subscription_month_key
        description: Surrogate key from (subscription_id, month_start_date) (PK).
        tests:
          - unique
          - not_null
      - name: month_start_date
        description: First day of the active calendar month.
        tests:
          - not_null
      - name: subscription_key
        description: The subscription this month belongs to.
        tests:
          - not_null
          - relationships:
              to: ref('dim_subscriptions')
              field: subscription_key
      - name: customer_key
        description: The paying customer (denormalized for one-join analysis).
        tests:
          - not_null
          - relationships:
              to: ref('dim_customers')
              field: customer_key
      - name: revenue_nzd
        description: Non-voided (PAID + POSTED) invoiced NZD in this month. 0 for voided-only months — never imputed.
        tests:
          - not_null
      - name: invoice_count
        description: Non-voided invoices in this month (0 or 1 in practice).
      - name: voided_invoice_count
        description: Voided invoices in this month (0 or 1 in practice). A 1 here with revenue 0 marks a voided-month revenue hole.
```

- [ ] **Step 3: Create `tests/assert_fct_revenue_reconciles_to_invoices.sql`**

```sql
-- The fact must reconcile exactly to the billing system: total fact revenue equals
-- the total of all non-voided source invoices. Returns rows (= fails) on mismatch.

with fct_total as (

    select sum(revenue_nzd) as total_nzd
    from {{ ref('fct_subscription_months') }}

),

invoice_total as (

    select sum(cast(total_nzd as decimal(18, 2))) as total_nzd
    from {{ source('subskribe', 'subskribe_invoices') }}
    where status != 'VOIDED'

)

select
    fct_total.total_nzd as fct_total_nzd,
    invoice_total.total_nzd as invoice_total_nzd
from fct_total
cross join invoice_total
where abs(fct_total.total_nzd - invoice_total.total_nzd) > 0.005
```

- [ ] **Step 4: Build the fact and run all its tests (including the singular test)**

Run: `.\.venv\Scripts\dbt.exe build --select fct_subscription_months`
Expected: 1 table created, all schema tests + `assert_fct_revenue_reconciles_to_invoices` PASS, exit 0.

- [ ] **Step 5: Verify fact shape**

Run (Bash tool): `./.venv/Scripts/python.exe -c 'import duckdb; c=duckdb.connect("tracksuit.duckdb", read_only=True); print(c.sql("SELECT count(*), sum(revenue_nzd), count(DISTINCT customer_key) FROM analytics.fct_subscription_months").fetchall())'`
Expected: `[(3594, Decimal('7904203.40'), 122)]` — 3,594 rows, total revenue exactly $7,904,203.40 NZD (= raw non-voided invoice total, pre-verified), all 122 customers represented.

- [ ] **Step 6: Checkpoint — manual commit (user)**

Suggested message: `feat: fct_subscription_months — monthly snapshot fact with exact revenue reconciliation test`

---

### Task 7: rpt_grr_by_size_segment — the reporting model

**Files:**
- Create: `models/marts/reporting/rpt_grr_by_size_segment.sql`
- Create: `models/marts/reporting/_reporting__models.yml`

- [ ] **Step 1: Create `models/marts/reporting/rpt_grr_by_size_segment.sql`**

```sql
-- Monthly Gross Revenue Retention by customer size segment, last 12 months.
-- Tracksuit's working definition: for month M, the cohort is customers with
-- revenue > 0 at M-12; each cohort customer's month-M revenue is capped at their
-- M-12 amount (the cap excludes expansion, making retention "gross");
-- GRR = sum(capped revenue at M) / sum(revenue at M-12), per segment.
--
-- The window anchors on the data horizon (latest fact month), not current_date,
-- so dbt build produces identical numbers whenever it runs. Output is sparse:
-- a (month, segment) row exists only where the segment had cohort revenue at
-- M-12 — grr_pct is never NULL and never divides by zero.

with subscription_months as (

    select * from {{ ref('fct_subscription_months') }}

),

customers as (

    select * from {{ ref('dim_customers') }}

),

customer_months as (

    select
        customer_key,
        month_start_date,
        sum(revenue_nzd) as revenue_nzd
    from subscription_months
    group by 1, 2

),

data_horizon as (

    select max(month_start_date) as horizon_month
    from subscription_months

),

report_months as (

    select cast(gs.generate_series as date) as month_start_date
    from data_horizon
    cross join generate_series(
        horizon_month - interval 11 month,
        horizon_month,
        interval 1 month
    ) as gs

),

cohort as (

    -- customers paying at M-12, with their baseline (denominator) revenue
    select
        report_months.month_start_date,
        customer_months.customer_key,
        customer_months.revenue_nzd as cohort_revenue_nzd
    from report_months
    inner join customer_months
        on customer_months.month_start_date
            = cast(report_months.month_start_date - interval 12 month as date)
    where customer_months.revenue_nzd > 0

),

retained as (

    -- month-M revenue per cohort customer, capped at the M-12 baseline;
    -- a customer with no month-M revenue contributes 0 (churn)
    select
        cohort.month_start_date,
        cohort.customer_key,
        cohort.cohort_revenue_nzd,
        least(
            coalesce(customer_months.revenue_nzd, 0),
            cohort.cohort_revenue_nzd
        ) as retained_revenue_nzd
    from cohort
    left join customer_months
        on customer_months.customer_key = cohort.customer_key
        and customer_months.month_start_date = cohort.month_start_date

)

select
    retained.month_start_date,
    customers.size_grouped,
    count(*) as cohort_customer_count,
    sum(retained.cohort_revenue_nzd) as cohort_revenue_nzd,
    sum(retained.retained_revenue_nzd) as retained_revenue_nzd,
    round(100.0 * sum(retained.retained_revenue_nzd) / sum(retained.cohort_revenue_nzd), 2) as grr_pct
from retained
inner join customers
    on retained.customer_key = customers.customer_key
group by 1, 2
```

- [ ] **Step 2: Create `models/marts/reporting/_reporting__models.yml`**

```yaml
version: 2

models:
  - name: rpt_grr_by_size_segment
    description: >
      Monthly Gross Revenue Retention by customer size segment for the last 12
      months, anchored on the data horizon (latest fact month) for reproducibility.
      Grain: month x size segment. SPARSE BY CONTRACT: a row exists only where the
      segment had cohort revenue at M-12; an absent row means GRR is undefined
      there, and grr_pct is never NULL. The 'Unknown' segment appears where its
      customers have cohort revenue — revenue is never silently dropped from a
      retention report. Cohort membership and the expansion cap both read
      fct_subscription_months.revenue_nzd, per Tracksuit's working GRR definition.
    tests:
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - month_start_date
            - size_grouped
      - dbt_utils.expression_is_true:
          expression: "grr_pct <= 100"
      - dbt_utils.expression_is_true:
          expression: "grr_pct >= 0"
    columns:
      - name: month_start_date
        description: First day of the report month M.
        tests:
          - not_null
      - name: size_grouped
        description: Customer size segment (Enterprise / Mid-Market / SMB / Startup / Unknown).
        tests:
          - not_null
          - accepted_values:
              values: ['Enterprise', 'Mid-Market', 'SMB', 'Startup', 'Unknown']
      - name: cohort_customer_count
        description: Customers in this segment who were paying at M-12 (the fixed cohort).
      - name: cohort_revenue_nzd
        description: The cohort's revenue at M-12 — the GRR denominator.
      - name: retained_revenue_nzd
        description: The cohort's month-M revenue, capped per customer at their M-12 amount — the GRR numerator.
      - name: grr_pct
        description: Gross Revenue Retention percentage. Bounded (0, 100] by the per-customer cap.
        tests:
          - not_null
```

- [ ] **Step 3: Build and test the report**

Run: `.\.venv\Scripts\dbt.exe build --select rpt_grr_by_size_segment`
Expected: 1 table created, all tests PASS, exit 0.

- [ ] **Step 4: Verify the report output and independently recompute one number**

The SQL needs string literals, so use a temp script. Create `_verify_rpt.py`:

```python
import duckdb

c = duckdb.connect("tracksuit.duckdb", read_only=True)

print("shape:", c.sql("""
    SELECT count(*), count(DISTINCT month_start_date),
           min(month_start_date), max(month_start_date),
           min(grr_pct), max(grr_pct)
    FROM analytics.rpt_grr_by_size_segment
""").fetchall())

print("May 2026 by segment:")
for r in c.sql("""
    SELECT * FROM analytics.rpt_grr_by_size_segment
    WHERE month_start_date = DATE '2026-05-01' ORDER BY size_grouped
""").fetchall():
    print(" ", r)

# Independent recomputation of (2026-05, Enterprise) straight from fct + dim —
# must equal the report's grr_pct for that row.
print("independent Enterprise May-2026 GRR:", c.sql("""
    WITH cm AS (
        SELECT customer_key, month_start_date, sum(revenue_nzd) AS rev
        FROM analytics.fct_subscription_months GROUP BY 1, 2
    ),
    coh AS (
        SELECT customer_key, rev AS base FROM cm
        WHERE month_start_date = DATE '2025-05-01' AND rev > 0
    )
    SELECT round(100.0 * sum(least(coalesce(m.rev, 0), coh.base)) / sum(coh.base), 2)
    FROM coh
    LEFT JOIN cm AS m
        ON m.customer_key = coh.customer_key
        AND m.month_start_date = DATE '2026-05-01'
    INNER JOIN analytics.dim_customers AS d
        ON d.customer_key = coh.customer_key
    WHERE d.size_grouped = 'Enterprise'
""").fetchall())
```

Run (Bash tool): `./.venv/Scripts/python.exe _verify_rpt.py`
Then delete: `rm _verify_rpt.py`

Expected:
- shape: 12 distinct months, min 2025-06-01, max 2026-05-01, all grr_pct in (0, 100], total rows ≤ 60
- May 2026 segment rows print with plausible values; Unknown appears only if its 2 customers had cohort revenue at 2025-05
- The independent Enterprise number **exactly matches** the report's (2026-05-01, Enterprise) grr_pct

- [ ] **Step 5: Checkpoint — manual commit (user)**

Suggested message: `feat: rpt_grr_by_size_segment — monthly GRR by size segment, last 12 months, horizon-anchored`

---

### Task 8: Full-build reproducibility check (fresh clone simulation)

**Files:** none created — verification only.

- [ ] **Step 1: Delete the database and rebuild from scratch**

Run: `Remove-Item .\tracksuit.duckdb -Confirm:$false; .\.venv\Scripts\python.exe load_raw_data.py`
Expected: 4 `loaded raw....` lines (120 / 122 / 330 / 3594 rows), `Done.`

- [ ] **Step 2: Full dbt build**

Run: `.\.venv\Scripts\dbt.exe build`
Expected: all 11 models build, ALL tests pass, exit 0. Note the final `Completed successfully` summary with counts (models / tests).

- [ ] **Step 3: Confirm the reporting model produced numbers**

Run (Bash tool): `./.venv/Scripts/python.exe -c 'import duckdb; c=duckdb.connect("tracksuit.duckdb", read_only=True); print(c.sql("SELECT count(*) FROM analytics.rpt_grr_by_size_segment").fetchone())'`
Expected: same row count as Task 7 Step 4 — identical numbers on a fresh build.

- [ ] **Step 4: Checkpoint — manual commit (user)** (only if any files changed; otherwise just report the build summary)

---

### Task 9: SUBMISSION.md

**Files:**
- Create: `SUBMISSION.md`

- [ ] **Step 1: Write `SUBMISSION.md`** with this content (the $7,904,203.40 figure is pre-verified against raw; re-confirm it matches the Task 6 Step 5 output before finishing the step):

````markdown
# Submission Notes

## How to run

```bash
python3 -m venv .venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install -r requirements.txt
python3 load_raw_data.py    # load raw CSVs into tracksuit.duckdb
dbt deps                    # installs dbt_utils
dbt build                   # builds all models and runs all tests
```

`dbt build` creates 11 models in the `analytics` schema and runs the full test
suite. The reporting model is `analytics.rpt_grr_by_size_segment` — monthly GRR by
customer size segment for the 12 months ending at the data horizon (May 2026).
Numbers are identical regardless of when you run it (see assumption 6).

## Project structure

- **staging** — 1:1 typed views over the four raw tables. No business logic.
- **intermediate** — `int_company_id_map` (CRM merge resolution) and
  `int_subscription_months` (bounded month spine + monthly invoice aggregates).
- **marts/core** — the dimensional model: `dim_customers` (grain: billing account),
  `dim_subscriptions` (grain: subscription), `fct_subscription_months`
  (grain: subscription × active month). Surrogate keys are generated here.
- **marts/reporting** — `rpt_grr_by_size_segment`, built only on the dim/fact.

## Key assumptions

1. **Customer = Subskribe billing account.** It's the paying entity, and it persists
   across renewals (subscription IDs change via `renewed_from_subscription_id`; the
   account doesn't). GRR cohorts therefore survive renewals by construction.
2. **Monthly revenue = non-voided (PAID + POSTED) invoiced NZD, bucketed by invoice
   calendar month.** POSTED counts: GRR measures retention of billing relationships,
   not cash collection, and POSTED clusters in recent months — excluding it would
   fake churn cliffs. See `docs/adr/0001-monthly-revenue-is-invoiced-truth.md`.
3. **A subscription's active window** runs from its start month to the earliest of
   end month, cancelled month, and the data horizon. Verified: bounded this way, the
   spine loses zero non-voided invoices and its only zero-revenue months are the 113
   voided-invoice months.
4. **Unmatchable CRM links become an 'Unknown' segment.** 11 of 13 non-matching
   `crmid`s resolve through `merged_object_ids`; the remaining 2 (`hsmissing_*`) stay
   in the model with `size_grouped = 'Unknown'` rather than being dropped — their
   revenue is real, and the Unknown row in the report is an actionable flag.
5. **`size_grouped` is treated as static** (HubSpot provides no history), so the
   current segment applies to all months.
6. **"Last 12 months" anchors on the data horizon** (`MAX(invoice month)` = May 2026),
   not `current_date`, so the build is reproducible. May 2026 is a complete billing
   month — every invoice in the data is issued on days 1–7 of its month.
7. **The GRR report is sparse:** a (month, segment) row exists only where the segment
   had cohort revenue at M-12. An absent row means "undefined", never NULL.

## Data quality notes

- **Merged CRM ids:** 11 accounts pointed at merged-away HubSpot ids — resolved by
  exploding `merged_object_ids` (no ambiguity: no old id maps to two survivors).
  2 accounts point at ids that don't exist anywhere (`crm_match_status='unmatched'`).
- **Voided invoices (113):** each sits alone in its month and was never re-issued, so
  each is a one-month revenue hole for an otherwise continuously billed subscription.
  Kept as honest zeros (flagged via `voided_invoice_count`), never imputed.
- **Renewal boundary double-billing:** 194 customer-months contain invoices from two
  subscriptions (old term's last bill + new term's first). Kept as invoiced truth; the
  GRR cap absorbs the numerator side, and the small denominator-side inflation is
  accepted and documented rather than smoothed.
- **Advance billing:** 307 invoices are dated up to 29 days before their
  subscription's start_date but never in an earlier calendar month, so invoice-month
  bucketing is safe.
- The fact reconciles exactly to the billing system — enforced by
  `tests/assert_fct_revenue_reconciles_to_invoices.sql` (total fact revenue = total
  non-voided invoice NZD = $7,904,203.40).
````

- [ ] **Step 2: Verify the embedded run instructions are accurate**

Cross-check the command list against SETUP.md and confirm `dbt deps` is included (packages.yml now exists). Confirm the `<verify>` placeholder was replaced with the real total.

- [ ] **Step 3: Checkpoint — manual commit (user)**

Suggested message: `docs: SUBMISSION.md — run instructions, assumptions, data quality notes`

---

### Task 10: PROMPTS.md

**Files:**
- Create: `PROMPTS.md`

- [ ] **Step 1: Write `PROMPTS.md`** — structure: each entry is *the prompt → the decision it shaped → how the output was verified*. Use this content as the draft (the user will edit for voice before committing):

```markdown
# AI Prompts That Shaped This Submission

Built with Claude Code. Not a transcript — these are the prompts that shaped real
decisions, with how each output was verified. Full design doc:
`docs/superpowers/specs/2026-06-04-subscriptions-dimensional-model-design.md`.

## 1. Structured brainstorm before any code

> *"I am working on the assignment task as part of tracksuit recruitment process.
> Please read the README and start planning on this together."*

**Shaped:** Instead of generating a project immediately, the AI profiled the raw data
first (row counts, PK uniqueness, orphan FKs, status distributions, merged-id
resolution) and then forced three explicit design decisions as multiple-choice
trade-offs: fact grain (monthly snapshot vs invoice-grain vs SCD2), customer entity
(account vs company grain), and dimension scope (separate dim_subscriptions vs
inline). I picked the recommended option each time, but the alternatives and
rejection reasons are recorded in the spec.

**Verified:** every claim the profiling made (e.g. "11 of 13 unmatched crmids resolve
via merged_object_ids") was a query I could re-run; the numbers appear as test
expectations in the implementation plan.

## 2. The challenge that redefined the fact's spine

> *(AI advisor review of the draft design)* "You verified ≤1 invoice per
> subscription-month. You did **not** verify ≥1 — if active months have invoice gaps,
> GRR's cohort and cap silently distort."

**Shaped:** The most important correction of the project. Naive spine (start_date →
end_date) showed 614 "gap" months. Investigation showed the monotonic gap pattern was
future months of ACTIVE subscriptions beyond the May-2026 data horizon, plus
post-cancellation months. Bounding the spine to
LEAST(end month, cancelled month, horizon) left exactly 113 gaps — 100% explained by
voided invoices. That bounded spine became the fact's definition.

**Verified:** by construction — the bounded spine was re-checked to lose zero
non-voided invoices, and the reconciliation test in `tests/` enforces it permanently.

## 3. Voided months: truth vs smoothing

> *"How should the 113 voided-invoice months be treated in the fact's revenue
> measure?"* (options: invoiced truth + flag / carry-forward fill / dual measures)

**Shaped:** Chose invoiced truth: revenue 0 + voided_invoice_count flag. Rejected
carry-forward (manufactures revenue never invoiced) and dual measures (two revenue
columns on a foundational fact recreates the inconsistent-answers problem). Recorded
as ADR 0001 because future readers will see paying customers drop to zero for exactly
one month and assume a bug.

**Verified:** all 113 voided invoices sit alone in their months (never re-issued),
checked by query; the fact's total reconciles exactly to non-voided invoice total.

## 4. My challenge to the AI: "should we keep the invoice status column?"

**Shaped:** Clarified layer responsibilities — status is kept and tested
(accepted_values) in staging as an early-warning system for new statuses, drives the
revenue filter in intermediate, and surfaces in the fact only as measures
(voided_invoice_count). Also surfaced the PAID vs POSTED call (assumption 2) and the
explicit decision NOT to split them into separate measures.

**Verified:** POSTED's recency clustering was confirmed by month-distribution query
before deciding it counts as revenue.

## 5. Grilling session against the spec

> *"Interview me relentlessly about every aspect of this plan…"*

**Shaped:** Six resolutions: surrogate keys generated in marts (CLAUDE.md amended to
match — it contradicted the spec); Unknown segment included in report output; fact
kept narrow (row existence = active, no derivable flags); the revenue ADR; sparse
report contract (no NULL grr_pct, no divide-by-zero); PROMPTS.md drafted by AI and
edited by me.

**Verified:** three new data checks came out of the grill — May 2026 is a complete
billing month (all invoices bill on days 1–7), the merge map cannot fan out (19 old
ids, no duplicates, no live-id collisions), and no subscription starts beyond the
horizon.

## What was delegated vs owned

Delegated to AI: data profiling queries, SQL drafting, schema.yml drafting, this
file's draft. Owned: every design decision above (made as explicit choices among
presented trade-offs), the final review of all committed code, and all commits.
```

- [ ] **Step 2: Ask the user to review and edit PROMPTS.md** — it speaks in their voice to their interviewer. Do not proceed to Task 11 until they've confirmed it reads true to them.

- [ ] **Step 3: Checkpoint — manual commit (user)**

Suggested message: `docs: PROMPTS.md — AI prompts that shaped real decisions, with verification notes`

---

### Task 11: Final verification sweep

**Files:** none — verification only.

- [ ] **Step 1: Confirm deliverables checklist against the brief**

Verify each exists and is committed (ask the user to confirm commit status):
- [ ] Dimensional model: `dim_customers`, `dim_subscriptions`, `fct_subscription_months`
- [ ] Reporting model: `rpt_grr_by_size_segment` (monthly GRR × segment, last 12 months)
- [ ] `SUBMISSION.md` (new file; README.md untouched)
- [ ] `PROMPTS.md` (user-reviewed)
- [ ] All models documented in schema.yml files; every model has PK tests; FKs have relationships tests

- [ ] **Step 2: One last clean-room build**

Run: `Remove-Item .\tracksuit.duckdb -Confirm:$false; .\.venv\Scripts\python.exe load_raw_data.py; .\.venv\Scripts\dbt.exe deps; .\.venv\Scripts\dbt.exe build`
Expected: end-to-end success, all tests passing — the exact sequence a reviewer will run.

- [ ] **Step 3: Report the final state to the user**

Summarize: model count, test count, GRR sample numbers (May 2026 by segment), and remind the user which files remain uncommitted (`git status`) so they can make the final commits and add the `tracksuit-technical-test` collaborator.
```
