# TODO

Open follow-ups for the Turista-to-PostgreSQL migration, found while
reviewing `run-pgloader-fullmigration.sh` and its supporting scripts against
the original `pgload` proof of concept.

## Open

| Priority | Item |
|---|---|
| P1 | Re-run/verify foreign-key generation+apply (`generate-postgres-fks.sh` + `psql -f postgres-fks.sql`, both already wired into `run-pgloader-fullmigration.sh`). The mechanism is proven — the `pgload` POC's `SESSION.md` recorded all 205 SQL Server foreign keys (incl. 40 composite) successfully applied to PostgreSQL — but an earlier check of the live PostgreSQL copy found 0 foreign keys. Confirm whether the full run actually completed end-to-end on the current database. |
| P2 | Fix the known `INCLUDE`-column index gap. Confirmed in the `pgload` POC (`SESSION.md`): SQL Server has 8 indexes using included/non-key columns; pgloader instead turns those into ordinary PostgreSQL key columns, producing 0 true `INCLUDE` indexes (and a related composite-index count mismatch, 59 vs. 61). Never fixed in `pgload`; carried over unchanged here. |
| P3 | Implement comment/description migration (decision made, see Done below). First verify against the SQL Server source's own `sys.extended_properties` (e.g. `MS_Description`) whether any tables/columns actually carry a comment — the previously observed "0 comments" was checked against the PostgreSQL copy, which proves nothing migrates them yet, not that the source has none. If the source has any, write a generator analogous to `generate-postgres-fks.sh` that emits `COMMENT ON TABLE` / `COMMENT ON COLUMN` statements only for entities that actually have one, apply it in `run-pgloader-fullmigration.sh`, and extend `compare-table-counts.sh` to check comment counts match. |

## Done

| Priority | Item |
|---|---|
| ✅ P3 | Scope decision: should table/column comments be migrated? **Decided: yes** — if a comment/description exists on the SQL Server side, migrate it to the matching PostgreSQL table/column comment. Do not invent or guess comments where none exist. |

## Related files

- `README.md` — full technical workflow, including "Verified results from the original proof of concept"
- `pgload/SESSION.md` (obsolete) — original verified FK/PK/index counts this workflow was proven against
- `pgload/pgloader-investigation.md` (obsolete) — pgloader worker/concurrency deadlock root-cause investigation
