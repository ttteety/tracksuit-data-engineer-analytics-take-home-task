"""
Load the raw take-home data into DuckDB.

This stands in for the EL tool (Fivetran) that lands raw data into our
warehouse in production. It reads the CSVs in data/raw/ and loads them, as-is,
into a `raw` schema inside a local DuckDB file (tracksuit.duckdb).

Run this ONCE before you run dbt:

    python load_raw_data.py

After it runs, the following tables exist in the `raw` schema:
    raw.hubspot_companies
    raw.subskribe_accounts
    raw.subskribe_subscriptions
    raw.subskribe_invoices

Declare these as dbt sources and build your models on top of them.
The data is intentionally loaded with minimal typing — treat it as raw.
"""

import duckdb
from pathlib import Path

DB_PATH = "tracksuit.duckdb"
RAW_DIR = Path(__file__).parent / "data" / "raw"

TABLES = {
    "hubspot_companies": "hubspot_companies.csv",
    "subskribe_accounts": "subskribe_accounts.csv",
    "subskribe_subscriptions": "subskribe_subscriptions.csv",
    "subskribe_invoices": "subskribe_invoices.csv",
}


def main():
    con = duckdb.connect(DB_PATH)
    con.execute("CREATE SCHEMA IF NOT EXISTS raw;")
    for table, csv_name in TABLES.items():
        path = (RAW_DIR / csv_name).as_posix()
        # Load everything as VARCHAR so the raw layer stays faithful to a
        # landed extract — type casting is the candidate's job in staging.
        con.execute(f"DROP TABLE IF EXISTS raw.{table};")
        con.execute(
            f"""
            CREATE TABLE raw.{table} AS
            SELECT * FROM read_csv('{path}', header=true, all_varchar=true);
            """
        )
        n = con.execute(f"SELECT count(*) FROM raw.{table};").fetchone()[0]
        print(f"  loaded raw.{table:<28} {n:>6} rows")
    con.close()
    print(f"\nDone. Raw data is in the `raw` schema of {DB_PATH}.")


if __name__ == "__main__":
    main()
