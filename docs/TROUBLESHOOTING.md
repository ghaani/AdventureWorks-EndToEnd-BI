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

## 3. `NULL` insert into an `IDENTITY` column caused by "Keep Identity"

**Phase:** 2 — SSIS, `Package_DimCurrency`
**Symptom:**
```
[OLE DB Destination] Error: SSIS Error Code DTS_E_OLEDBERROR. An OLE DB error has occurred.
Cannot insert the value NULL into column 'CurrencyKey', table 'AdventureWorksDW_Custom.dbo.DimCurrency';
column does not allow nulls. INSERT fails.
```

**Root cause:**
`CurrencyKey` is defined as `INT IDENTITY(1,1)` — SQL Server generates it automatically and no value
should be supplied from the Data Flow. The OLE DB Destination's **"Keep Identity"** option was checked,
which tells SSIS to explicitly pass a value for the identity column instead of letting SQL Server
generate one. Since the source query has no `CurrencyKey` column to map, SSIS passed `NULL`, which
violated the `NOT NULL` constraint on the identity column.

**Fix:** unchecked **"Keep Identity"** in the OLE DB Destination's Connection Manager settings, so SQL
Server generates `CurrencyKey` values itself on insert. (A related but different mistake to watch for:
mapping the identity column to `<ignore>` in the Mappings tab — that alone doesn't fix it if "Keep
Identity" is still checked.)

**Lesson:** for every dimension load, the surrogate `IDENTITY` key should never receive a value from
the source system — both the Mappings tab (`<ignore>` for the key column) *and* "Keep Identity" being
unchecked are required. This applies to every Type 1 and Type 2 dimension package in this project.

---

## 4. `FullName` truncation warning from concatenated first/last name

**Phase:** 2 — SSIS, `Package_DimSalesPerson`
**Symptom:**
```
[OLE DB Destination] Warning: Truncation may occur due to inserting data from data flow column
"FullName" with a length of 101 to database column "FullName" with a length of 100.
```

**Root cause:**
`DimSalesPerson.FullName` (and, by the same pattern, `DimCustomer.FullName`) was defined as
`NVARCHAR(100)` in the Phase 1 DDL, populated via `FirstName + ' ' + LastName`. In the OLTP source,
`Person.FirstName` and `Person.LastName` are each up to 50 characters, so the worst case is
`50 + 1 (space) + 50 = 101` characters — one character over the column's limit.

**Fix:** widened both `DimSalesPerson.FullName` and `DimCustomer.FullName` to `NVARCHAR(150)`, and
updated the original `01_create_dw_schema.sql` so a fresh run of the project doesn't hit the same
warning.

**Lesson:** when a dimension column is built by concatenating two source columns, size it against the
*sum* of the source columns' max lengths (plus any separator), not an arbitrary round number. A quick
DDL review catches this before it becomes a runtime warning.

---

## 5. `FactResellerSales` was missing `CurrencyKey`

**Phase:** 2 — SSIS, `Package_FactResellerSales` (caught while writing the OLE DB Source query)
**Symptom:** not a runtime error — a design gap noticed while building the Reseller Sales source
query and comparing it against `FactInternetSales`.

**Root cause:**
The original Phase 1 DDL gave `FactInternetSales` a `CurrencyKey` but left it off
`FactResellerSales`. This wasn't a deliberate business decision — `Sales.SalesOrderHeader.CurrencyRateID`
applies to every order in OLTP regardless of whether the customer is an Internet customer or a
reseller/store, so there was no real reason to track currency on one fact table and not the other. It
was simply missed when the schema was first designed.

**Fix:**
- `sql/migrations/002_add_currencykey_to_factresellersales.sql` — adds `CurrencyKey` to the existing
  table via `ALTER TABLE`, defaulting existing/future unmatched rows to the Unknown Member (`0`).
- `01_create_dw_schema.sql` updated so a fresh build of the database includes the column from the
  start.
- `sql/source_factresellersales.sql` updated to resolve `CurrencyCode_BK` the same way
  `FactInternetSales` does (via `Sales.CurrencyRate`, defaulting to `'USD'` for domestic orders).

**Lesson:** when two fact tables share a conceptually similar grain (line item, tied to an order
header), it's worth explicitly diffing their column lists against each other during schema design —
not just against the source system — to catch this kind of asymmetry before packages are built around
the gap.

---

## 6. `SalesOrderLineNumber` overflow — global identity used instead of per-order line number

**Phase:** 2 — SSIS, `Package_FactResellerSales` (bug also present in `Package_FactInternetSales`)
**Symptom:**
```
[OLE DB Destination] Error: ... "Invalid character value for cast specification".
[OLE DB Destination] Error: ... Columns[SalesOrderLineNumber] ... "Conversion failed because the
data value overflowed the specified type."
```

**Root cause:**
The source query used `sod.SalesOrderDetailID` directly as `SalesOrderLineNumber`. But
`SalesOrderDetailID` is a **global identity** across the entire `Sales.SalesOrderDetail` table
(spanning all ~121,317 rows across every order), not a line number scoped to a single order.
`FactInternetSales.SalesOrderLineNumber` / `FactResellerSales.SalesOrderLineNumber` are defined as
`TINYINT` (max 255) in the Phase 1 DDL, since a "line number within one order" was always expected to
be small — so any row with a global `SalesOrderDetailID` above 255 overflowed the column on insert.

**Fix:** replaced the column reference with a windowed row number scoped to each order:
```sql
ROW_NUMBER() OVER (PARTITION BY sod.SalesOrderID ORDER BY sod.SalesOrderDetailID) AS SalesOrderLineNumber
```
This restarts the count at 1 for every `SalesOrderID`, matching what the column was actually meant to
represent, and comfortably fits in `TINYINT` since no single order has anywhere near 255 line items.
Applied to both `source_factinternetsales.sql` and `source_factresellersales.sql`.

**Follow-up required:** `FactInternetSales` was built before this bug was found and needs to be
truncated and reloaded with the corrected query — any rows already loaded have an incorrect
(and possibly overflow-avoiding-by-luck) `SalesOrderLineNumber`.

**Lesson:** when a source system's identity/primary key column looks like it could serve as a
"line number," check whether it's scoped to the parent entity (per-order) or global to the whole
table before assuming the two are interchangeable — the data type chosen in the DW schema is a strong
hint at which one was intended.

---

## 7. Orphaned `'Running'` rows in `ETL_ExecutionLog` from interrupted debug runs

**Phase:** 2 — SSIS, `Package_Master` event handlers
**Symptom:** multiple rows in `dbo.ETL_ExecutionLog` for what felt like a single execution, some stuck
at `Status = 'Running'` with `EndTime IS NULL` forever.

**Root cause:** not a bug in the `OnPreExecute` / `OnPostExecute` / `OnError` event handler logic
itself. Stopping a package mid-run in Visual Studio (Stop Debugging, or killing an in-progress
execution) ends the run abnormally — neither `OnPostExecute` (normal success) nor `OnError` (normal
failure) gets a chance to fire, since the package never reaches a natural completion state. The
`'Running'` row inserted by `OnPreExecute` at the start is simply never updated. Repeatedly
starting-and-stopping a run while testing (e.g. while wiring up the event handlers themselves)
produces one stale `'Running'` row per interrupted attempt.

**Not fixed — accepted as a known limitation.** This only happens during interactive debugging in
Visual Studio; a package invoked by SQL Server Agent (the real deployment scenario) either completes
normally or is caught by `OnError`, so orphaned rows shouldn't occur in production use. Stale rows can
be identified and cleaned up manually with:
```sql
SELECT * FROM dbo.ETL_ExecutionLog WHERE Status = 'Running';
-- after confirming these are genuinely abandoned (not an actual in-progress run):
DELETE FROM dbo.ETL_ExecutionLog WHERE Status = 'Running' AND StartTime < DATEADD(HOUR, -1, GETDATE());
```

**Lesson:** logging schemes built around start/end event pairs always need to account for the "started
but never cleanly finished" case — whether from a debugger stop, a server crash, or a killed process —
rather than assuming every `'Running'` row will eventually be closed out.

---

<!-- Add new entries below this line as the project progresses. -->
