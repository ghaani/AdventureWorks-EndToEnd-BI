/* =====================================================================
   Package_DimDate — SQL used inside the "Populate DimDate" Execute SQL Task
   Generates one row per calendar day for a fixed date range.
   AdventureWorks OLTP order dates fall roughly between 2011 and 2014,
   so the range below comfortably covers all fact data plus headroom.
   Fiscal year at AdventureWorks starts July 1st.
   ===================================================================== */

USE AdventureWorksDW_Custom;
GO

/* -----------------------------------------------------------------
   IDEMPOTENCY GUARD
   DimDate is a static dimension: it is populated once for a fixed
   date range and is not meant to be wiped and rebuilt on every ETL
   run. Once FactInternetSales / FactResellerSales contain real rows,
   a DELETE + re-INSERT approach breaks (DELETE is blocked on
   referenced rows, and re-INSERT hits a PRIMARY KEY violation on the
   dates that survive). So instead of deleting anything, this script
   simply exits early if DimDate already has data. Re-running this
   Execute SQL Task as part of Package_Master is therefore always
   safe and has no effect after the first successful run.
   ----------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM dbo.DimDate)
BEGIN
    PRINT 'DimDate already populated — skipping.';
    RETURN;
END

DECLARE @StartDate DATE = '2010-01-01';
DECLARE @EndDate   DATE = '2016-12-31';
DECLARE @CurrentDate DATE = @StartDate;

WHILE @CurrentDate <= @EndDate
BEGIN
    INSERT INTO dbo.DimDate (
        DateKey, FullDate, DayOfWeek, DayName, DayOfMonth, DayOfYear,
        WeekOfYear, MonthNumber, MonthName, Quarter, QuarterName,
        Year, IsWeekend, FiscalYear, FiscalQuarter
    )
    VALUES (
        CONVERT(INT, FORMAT(@CurrentDate, 'yyyyMMdd')),
        @CurrentDate,
        DATEPART(WEEKDAY, @CurrentDate),
        DATENAME(WEEKDAY, @CurrentDate),
        DATEPART(DAY, @CurrentDate),
        DATEPART(DAYOFYEAR, @CurrentDate),
        DATEPART(WEEK, @CurrentDate),
        DATEPART(MONTH, @CurrentDate),
        DATENAME(MONTH, @CurrentDate),
        DATEPART(QUARTER, @CurrentDate),
        'Q' + CAST(DATEPART(QUARTER, @CurrentDate) AS VARCHAR(1)),
        DATEPART(YEAR, @CurrentDate),
        CASE WHEN DATEPART(WEEKDAY, @CurrentDate) IN (1,7) THEN 1 ELSE 0 END,
        -- Fiscal year: if month >= July, fiscal year = calendar year + 1
        CASE WHEN DATEPART(MONTH, @CurrentDate) >= 7
             THEN DATEPART(YEAR, @CurrentDate) + 1
             ELSE DATEPART(YEAR, @CurrentDate)
        END,
        -- Fiscal quarter: July-Sep = Q1, Oct-Dec = Q2, Jan-Mar = Q3, Apr-Jun = Q4
        CASE
            WHEN DATEPART(MONTH, @CurrentDate) IN (7,8,9)   THEN 1
            WHEN DATEPART(MONTH, @CurrentDate) IN (10,11,12) THEN 2
            WHEN DATEPART(MONTH, @CurrentDate) IN (1,2,3)   THEN 3
            ELSE 4
        END
    );

    SET @CurrentDate = DATEADD(DAY, 1, @CurrentDate);
END
GO

-- Sanity check
SELECT COUNT(*) AS TotalDays, MIN(FullDate) AS FirstDate, MAX(FullDate) AS LastDate
FROM dbo.DimDate;
GO
