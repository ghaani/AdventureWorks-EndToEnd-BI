# Migrations

This folder holds incremental changes applied to an **already-created** `AdventureWorksDW_Custom`
database — the kind of fix you make with `ALTER TABLE` instead of recreating a table from scratch,
so existing data isn't lost.

## Why this exists separately from `01_create_dw_schema.sql`

`01_create_dw_schema.sql` in the parent folder always reflects the **current, correct** schema — if
you're setting up the database for the first time, that single script is all you need.

The scripts in this folder are a historical record of schema bugs found *after* the database already
existed, and the exact `ALTER` statements used to fix them in place. Each one corresponds to an entry
in [`docs/TROUBLESHOOTING.md`](../../docs/TROUBLESHOOTING.md).

## Naming convention

```
NNN_short_description.sql
```
Numbered in the order the fixes were applied, e.g. `001_fix_fullname_column_size.sql`.

## Index

| Script | Troubleshooting entry |
|---|---|
| `001_fix_fullname_column_size.sql` | [#4 — FullName truncation warning](../../docs/TROUBLESHOOTING.md#4-fullname-truncation-warning-from-concatenated-firstlast-name) |
| `002_add_currencykey_to_factresellersales.sql` | [#5 — FactResellerSales missing CurrencyKey](../../docs/TROUBLESHOOTING.md#5-factresellersales-was-missing-currencykey) |
