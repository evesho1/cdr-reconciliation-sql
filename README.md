# CDR Reconciliation (MySQL)

Reconciles a month of telecom call records from two independent sources: an interconnect billing log (LCL) and a switch-level call detail record export (CDR). The goal is to find out how many calls match across both systems and where they diverge. The full pipeline, from raw CSV load to reconciliation, is written in MySQL.

## Tools Used

- **MySQL 8.0** for loading, cleaning, normalisation and reconciliation joins

## Approach

1. **Staging load.** Both CSVs are loaded into all-text staging tables so malformed rows don't abort the import.
2. **Number normalisation.** Phone numbers arrived in inconsistent formats (trailing `.0`, leading `+`, zero-padding, and network prefixes of different lengths). These were standardised to a common subscriber number before matching. Several of these only became visible by inspecting the columns as raw text, since numeric coercion silently hides them.
3. **Data quality fixes.** Stray header rows embedded in the CDR export are filtered out, and dates are validated by pattern before parsing to avoid strict-mode errors.
4. **Join-key investigation.** The obvious key (caller number) matched only ~38% of records, while callee number matched ~77%. Sample values showed the "caller" fields represent different things in each system, so callee number became the join key and caller agreement is reported as a flag.
5. **Cardinality checks.** Duplicate counts are checked per key before every join, because a join on a low-cardinality key such as duration alone multiplies rows into a near-cross join.
6. **Three reconciliation sets:**
   - **Set 1:** match on callee number
   - **Set 2:** match on callee number + call duration
   - **Set 3:** Set 2 plus the time difference between the two systems' call start times

Full methodology and walkthrough → [Notion page](ADD_NOTION_LINK_HERE)

## Key Findings

- _Add your headline match rates for Sets 1–3 here_
- _Add what the time-difference distribution in Set 3 showed_

## How to Run

1. Place the two input files in a `data/` folder as `lcl_june_2025.csv` and `cdr_june_2025.csv`.
2. Enable local file loading: `SET GLOBAL local_infile = 1;`
3. Run: `mysql --local-infile=1 -u <user> -p < cdr_reconciliation.sql`

The analysis window is set by `@date_start` and `@date_end_exclusive` at the top of the script.

## Note on Data

Source data is not included in this repository. All company and network operator names have been removed to protect proprietary information.
