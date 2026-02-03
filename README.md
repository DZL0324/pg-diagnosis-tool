# PG AWR Snapshot Tool

This repository contains:

- `pg_awr_report.sh`: AWR-style snapshot report generator (Markdown output).
- `web_app.py`: Minimal web UI that runs the snapshot script and renders output.

## Requirements

- `psql` available on the host.
- PostgreSQL credentials via environment variables or the web UI.

## Run the CLI report

```bash
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=your_password
export PGDATABASE=postgres

./pg_awr_report.sh -i 60
```

## Run the web UI

```bash
export PORT=8000
python3 web_app.py
```

Then open `http://localhost:8000` and fill in the connection details.
