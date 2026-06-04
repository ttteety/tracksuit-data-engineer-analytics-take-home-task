# Setup — getting dbt running locally

This covers everything you need to get the project running. You'll be working
against **DuckDB**, a local file-based database, so there's nothing to install in
the cloud and no credentials to manage. Everything runs on your machine.

The task itself (what to build and what we're looking for) is in
[`README.md`](./README.md).

## Prerequisites

- Python 3.9+
- That's it.

## 1. Install dbt

```bash
# Create and activate a virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dbt (with the DuckDB adapter) and duckdb
pip install -r requirements.txt
```

> 💡 These commands use `python3`, which is what macOS and most Linux setups
> ship. If `python3` isn't found on your machine, use whatever invokes Python
> 3.9+ for you (e.g. `python`). On Windows, activate the venv with
> `.venv\Scripts\activate` instead of the `source` line above.

Once the virtual environment is active, your prompt will show `(.venv)` and both
`python` and `pip` will resolve inside it.

## 2. Load the raw data

The raw CSVs in `data/raw/` represent data as it lands in our warehouse from our
source systems (HubSpot and Subskribe), before any transformation. Load them into
DuckDB with:

```bash
python3 load_raw_data.py
```

This creates a local `tracksuit.duckdb` file with a **`raw`** schema containing
four tables:

| Table | Source |
|---|---|
| `raw.hubspot_companies` | HubSpot (CRM) |
| `raw.subskribe_accounts` | Subskribe (billing) |
| `raw.subskribe_subscriptions` | Subskribe (billing) |
| `raw.subskribe_invoices` | Subskribe (billing) |

These are your **sources**. Declare them in your dbt project and build your models
on top of them. (Column-level details are in the `README.md` Data Description.)
The data is loaded as-is — treat it as raw landed data, with all the quirks that
implies.

## 3. Run dbt

dbt is already pointed at the same `tracksuit.duckdb` file (see `profiles.yml`).
A normal loop looks like:

```bash
dbt deps      # only if you add packages to packages.yml
dbt build     # runs your models + tests
```

After you've built your models, we should be able to clone your repo, run
`python3 load_raw_data.py` and then `dbt build`, and see your models — including
your reporting model — produce results. Please make sure that works before you
submit.

## Inspecting the database

Handy if you want to poke at the data or check your output. The `duckdb` Python
library is already installed (it came in via `requirements.txt`), so you can
query the database without any extra tools:

```bash
python3 -c "import duckdb; print(duckdb.connect('tracksuit.duckdb').sql('SELECT * FROM raw.subskribe_subscriptions LIMIT 10'))"
```

Prefer an interactive SQL prompt? Install the optional DuckDB CLI
(`brew install duckdb` on macOS, or see duckdb.org/docs/installation), then:

```bash
duckdb tracksuit.duckdb
# at the duckdb prompt (not your shell), run SQL then quit:
#   SELECT * FROM raw.subskribe_subscriptions LIMIT 10;
#   .quit
```

If anything here doesn't run, reach out — a setup snag shouldn't eat into your
time on the actual task.
