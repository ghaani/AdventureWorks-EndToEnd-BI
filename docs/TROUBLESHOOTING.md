# Challenges & Lessons Learned

A running log of real issues hit while building this project, why they happened, and how they were
fixed. Kept intentionally honest and technical — this is meant to show actual engineering judgment,
not just a finished pipeline.

---

## 1. `TRUNCATE TABLE` blocked by an empty child table's Foreign Key

**Phase:** 2 — SSIS, `Package_DimDate`
**Symptom:**
```
Executing the query "TRUNCATE TABLE dbo.DimDate;" failed with the following error:
"Cannot truncate table 'dbo.DimDate' because it is being referenced by a FOREIGN KEY constraint."
```

**Root cause:**
SQL Server disallows `TRUNCATE TABLE` on any table that is referenced by a `FOREIGN KEY` from another
table — even if that other table currently has zero rows. `FactInternetSales` and `FactResellerSales`
both hold a FK to `DimDate.DateKey`, so the truncate was rejected purely on schema grounds, regardless
of actual data.

**Fix (first pass):** replaced `TRUNCATE TABLE dbo.DimDate` with `DELETE FROM dbo.DimDate`, since
`DELETE` is evaluated row by row and succeeds as long as no *existing* fact row references the rows
being deleted.

**Follow-up problem this exposed:** a delete-then-reinsert pattern is not safe to re-run once the fact
tables actually contain data — see issue #2 below.

---

## 2. Delete-and-reload pattern is not idempotent for a static dimension

**Phase:** 2 — SSIS, `Package_DimDate`
**Question that surfaced it:** "Does `DimDate` get wiped and reloaded every time the project runs?"

**Root cause:**
`DimDate` is a static dimension — it doesn't change over time and isn't sourced from the OLTP system.
The original script deleted all rows and reinserted the full 2010–2016 range on every execution. This
works only while the fact tables are empty. Once `FactInternetSales` / `FactResellerSales` are loaded
with real rows pointing at specific `DateKey` values:
- `DELETE` would fail (or partially fail) on any date row that a fact row now references, and
- even where `DELETE` succeeds, the following `INSERT` would violate the `PRIMARY KEY` on `DateKey`
  for any date that still exists in the table.

**Fix:** added an idempotency guard at the top of the script:
```sql
IF EXISTS (SELECT 1 FROM dbo.DimDate)
BEGIN
    PRINT 'DimDate already populated — skipping.';
    RETURN;
END
```
The script now populates `DimDate` exactly once. Re-running the same Execute SQL Task later (e.g. as
part of `Package_Master`) is always safe and has no effect after the first successful run.

**Lesson:** for any *static* dimension, "safe to re-run" (idempotent) is a more important design goal
than "always fresh." Only dimensions whose source data actually changes (e.g. `DimProduct`,
`DimCustomer` via SCD Type 2, or Type 1 dimensions refreshed from OLTP) should be reloaded on every
run — and even then, via `UPDATE`/`MERGE` logic rather than `DELETE` + full reinsert.

---

<!-- Add new entries below this line as the project progresses. -->
