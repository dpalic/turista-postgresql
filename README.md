# Turista to PostgreSQL

This project copies the complete database of the W&W Turista Windows
application from Microsoft SQL Server to PostgreSQL.

The PostgreSQL copy provides an open-source database foundation for reporting,
data analysis, migration projects, and integrations with other systems. It
preserves the source tables and data instead of limiting access to a small
application-specific export.

This is a database migration and offloading tool. It does not replace Turista,
add a REST API to Turista, or continuously synchronize later changes unless
such synchronization is implemented separately. Options for extending this
approach are described in
[Further integration and migration support](#further-integration-and-migration-support).

## Table of contents

- [Management summary](#management-summary)
- [Important operational notes](#important-operational-notes)
- [Integration examples](#integration-examples)
- [Motivation](#motivation)
- [What the migration does](#what-the-migration-does)
- [Developer information](#developer-information)
- [License and product names](#license-and-product-names)
- [Limitations, exclusions, and drawbacks](#limitations-exclusions-and-drawbacks)
- [Further integration and migration support](#further-integration-and-migration-support)

## Management summary

The project is intended to reduce dependency on a Windows-only application
database by creating an independently accessible PostgreSQL copy. The expected
business outcomes are broader data access, easier integration, improved
reporting, and a controlled foundation for future migration or modernization
work without modifying the operational Turista installation.

The documented migration design includes the following operational controls:

- Complete table and data transfer instead of a limited application export.
- Reconstruction and validation of primary-key and foreign-key relationships,
  including composite foreign keys.
- Source-to-target row-count and structural comparisons for reconciliation.
- Date and time validation to detect timezone-related migration errors.
- Configurable fail, warn, or ignore behavior for timezone mismatches.
- Separation of credentials from tracked source files through environment
  variables and a Git-ignored `.env` file.
- Repeatable execution through scripted migration and validation steps.

## Important operational notes

The scripting and tooling were used and verified on Ubuntu
`24.04.4 LTS (Noble Numbat)`. Other operating-system versions may work but
have not been validated by this project and may require dependency or
configuration changes.

The pgloader configuration uses `include drop`. Existing target objects may be
dropped and recreated. Run it only against the intended PostgreSQL migration
database and take a backup first when the target contains valuable data.

This workflow creates a point-in-time copy. Changes made in Turista after the
migration are not transferred automatically.

The copied database may contain personal, financial, passport, contact, and
other sensitive data. Apply appropriate access control, encryption, backup,
retention, and data-protection policies to the PostgreSQL system.

Writing directly to the PostgreSQL copy does not write changes back to
Turista. Treat the copy as read-only unless a separate application explicitly
owns and documents write operations.

## Integration examples

Once migrated, the PostgreSQL database can be used as a source for:

- ERP and CRM migrations (in our case, ERPNext for both)
- Reporting and business intelligence
- Data warehouses and ETL pipelines
- Search and customer-service applications
- Custom REST or GraphQL services
- Event-driven integration processes
- Data quality and reconciliation tooling

Because PostgreSQL is broadly supported, the migrated database can also be
integrated with hyperscalers and modern application platforms, including:

- Amazon Web Services (AWS), for example Amazon RDS for PostgreSQL
- Google Cloud, for example Cloud SQL for PostgreSQL
- Microsoft Azure, for example Azure Database for PostgreSQL
- Kubernetes-based application and data platforms
- Docker-based development, integration, and deployment environments
- Cloud Foundry applications and services

The PostgreSQL database may be self-managed or hosted by a cloud provider.
Applications running on these platforms can access it through standard
PostgreSQL drivers, integration services, ETL tools, or a separately developed
API.

## Motivation

Integrating Turista into a distributed systems environment can be difficult.
The application is Windows-only, while many modern integration platforms and
services are built around open REST APIs, Linux-compatible tooling, and
open-source databases.

The motivation for this project is based on the following integration
limitations:

- Lack of a complete REST API for reading your own data.
- Lack of complete read and write operations at API level.
- Lack of API support for some mandatory integration use cases.
- Lack of native cloud integration for connecting the application and its data
  to Amazon Web Services (AWS), Google Cloud, Microsoft Azure, Kubernetes,
  Docker, Cloud Foundry, and other cloud-hosted or distributed systems.
- Lack of a web-based client that can be used without installing and operating
  a Windows fat-client application.
- Lack of either a web client or native client support for macOS and Linux
  workstations.
- Lack of either a web client or native mobile and tablet clients for Android,
  iPhone, and iPad devices.
- Lack of customizable user interfaces that can pre-fill customer or lead data
  collected through shops, websites, landing pages, or other external systems
  and transfer it into Turista workflows.
- Lack of bidirectional synchronization for offers and product content between
  Turista and shops or websites, especially when those channels use richer and
  more detailed descriptions, pictures, documents, metadata, and other
  digital content than Turista can represent directly.
- Increased complexity when connecting Windows-specific applications to
  heterogeneous or distributed environments.

Copying the complete database to PostgreSQL makes the data accessible through
standard SQL and the broad PostgreSQL ecosystem. Teams can then build their
own controlled interfaces, REST services, ETL processes, reports, or
connections to ERP, CRM, analytics, and automation systems. They can also
develop browser-based or mobile-friendly applications without requiring the
original Windows fat client on every end-user device.

PostgreSQL does not expose a REST API by itself. If REST access is required, a
separate service or PostgreSQL-compatible API layer must be placed in front of
the migrated database.

## What the migration does

From a business perspective, the migration creates a complete, independently
accessible PostgreSQL copy of the Turista database. This enables an
organization to:

- Access its Turista data through standard, open SQL interfaces.
- Use the data for reporting, analytics, data quality, and reconciliation.
- Connect ERP, CRM, websites, shops, cloud services, and automation platforms.
- Build customized web, desktop, mobile, and tablet applications.
- Develop controlled REST, GraphQL, ETL, or event-driven integration services.
- Preserve the original Turista database structure as a basis for migration
  and integration work.
- Validate that the transferred data and important database relationships
  match the source system.

The result is a point-in-time integration database. It does not change the
Turista application or automatically synchronize later changes.

For implementation details, see [Developer information](#developer-information).

## Developer information

### Technical migration workflow

The full technical workflow:

1. Reads the Turista database from Microsoft SQL Server.
2. Creates the corresponding schemas and tables in PostgreSQL.
3. Copies all table data.
4. Creates indexes, primary keys, and resets sequences.
5. Generates PostgreSQL foreign keys from SQL Server metadata.
6. Applies the generated foreign keys, including composite foreign keys.
7. Compares source and target row counts and database structures.

Foreign keys are generated separately because pgloader does not correctly
reproduce all composite SQL Server foreign keys found in this database.
Pgloader instead tried to create separate single-column foreign keys for
composite SQL Server foreign keys, which PostgreSQL rejected with
`there is no unique constraint matching given keys for referenced table`.

Do not re-enable pgloader's own `foreign keys` option in the `.load`
template unless pgloader's MSSQL composite-foreign-key handling has been
fixed upstream or manually re-verified against this database — `no foreign
keys` plus the separate `generate-postgres-fks.sh` step is the workaround,
not an optional simplification.

### Verified results from the original proof of concept

This workflow (and its foreign-key and index handling specifically) was
proven against a real run before being adopted here. The findings below come
from the original `pgload` proof-of-concept project, which this repository
replaced; that project is now obsolete and its findings are recorded here
instead.

Foreign keys, verified working end to end:

- SQL Server source: 205 enabled/trusted foreign keys, 40 of them composite,
  none disabled or untrusted.
- After running `generate-postgres-fks.sh` and applying the result: PostgreSQL
  matched exactly — 205 foreign keys (40 composite), all validated, and 733
  primary keys (355 composite).

Known, still-open index gap — not a regression in this repository, never
fixed in the proof of concept either:

- SQL Server has 8 indexes that use included (non-key) columns. Pgloader's
  `create indexes` step does not reproduce PostgreSQL's `INCLUDE` clause; it
  instead adds those columns as ordinary key columns. The verified result was
  0 true `INCLUDE` indexes in PostgreSQL versus 8 in SQL Server, plus a
  related composite-index count mismatch (61 in PostgreSQL versus 59 in SQL
  Server). `compare-table-counts.sh` reports this as `indexes_with_includes`
  and `indexes_composite` differences; treat any such difference as expected
  until this is fixed.

### Included scripts

- `run-pgloader-fullmigration.sh` runs the complete migration and validation,
  including the foreign-key recreation and the timezone check
  (`check-timezones.sh`). What happens when the timezone check finds a
  mismatch is controlled by `TIMEZONE_MISMATCH_ACTION` (see Configuration).
- `mssql-to-postgres.load.template` defines the pgloader database migration,
  with connection details left as `${VARIABLE}` placeholders.
  `run-pgloader-fullmigration.sh` renders it into `mssql-to-postgres.load`
  (Git-ignored) using `envsubst` and the values from `.env`.
- `mssql-anschriften-only.load.template` is the same idea, scoped to a single
  table, for manual ad hoc loads.
- `generate-postgres-fks.sh` generates PostgreSQL foreign-key DDL from SQL
  Server metadata. It also resolves mixed-case PostgreSQL table names from
  the target catalog (using `PGPASSWORD`/Perl), because pgloader preserves
  some source identifiers verbatim, including non-ASCII characters — for
  example `public."Beförderungsarten"`.
- `compare-table-counts.sh` compares row counts, keys, foreign keys, indexes,
  and referential-integrity metadata. Pass `--db-both` to only gather and
  print per-table row counts for both databases (skip the key/FK/index
  comparison), or `--db-mssql-only`/`--db-postgresql-only` to do the same for
  just one side, without connecting to the other at all — e.g. to inspect
  either side on its own before the other is ready.
- `check-timezones.sh` checks timezone correctness end to end: the SQL Server
  host clock/timezone, the SQL Server `date`/`time`/`datetime`/
  `datetimeoffset` column census, the PostgreSQL host/session timezone, the
  PostgreSQL date/time column census, and finally a per-column MIN/MAX/COUNT
  comparison between SQL Server and PostgreSQL to confirm the migrator
  actually moved every date/time value correctly (not just that the schema
  looks plausible).
- `postgres-fks.sql` is generated during the migration and then applied to
  PostgreSQL.
- `env_loader.sh` is a small shared helper, sourced by the shell scripts, that
  loads `.env` while letting already-exported shell variables take
  precedence.
- `.env-example` is the safe template for `.env`. Copy it and fill in real
  values: `cp .env-example .env`. `.env` is excluded from Git.
- `freetds.conf.example` is the safe template for the system FreeTDS config
  described below.

### Dependencies

The migration host needs:

- Bash and standard Unix command-line tools
- PostgreSQL client tools, including `psql`
- A reachable PostgreSQL server
- A patched source build of `pgloader` with Microsoft SQL Server support
- FreeTDS and its DB-Library implementation
- Microsoft `sqlcmd` from `mssql-tools18`
- Perl, used while resolving PostgreSQL identifiers in the generated
  foreign-key statements
- Network access to the Turista SQL Server
- A SQL Server account with permission to read all required tables and system
  metadata
- A PostgreSQL account allowed to create and modify the target database

The helper scripts also use common utilities such as `sed`, `sort`, `join`,
`column`, `mktemp`, and `tr`.

Connect to PostgreSQL over TCP (`-h 127.0.0.1` or another explicit host), not
the local Unix socket — socket access through `/var/run/postgresql` can fail
with a peer-authentication error even when TCP with a password works fine.

### Patched pgloader build

The Turista migration required a locally built and patched version of
`pgloader`. The runner currently uses:

```text
/root/pgloader/build/bin/pgloader
```

The patch changes pgloader's FreeTDS/DB-Library initialization so that:

- The maximum number of DB-Library processes is configured from
  `TDS_MAX_CONN`, with a default of 512.
- The misleading FreeTDS message `Max connections reached, increase value of
  TDS_MAX_CONN` is ignored when DB-Library continues to execute the request
  successfully.

This patch was needed for the tested Turista environment. A standard packaged
pgloader installation must not be assumed to behave identically. Build and
test the patched pgloader version before running a production migration.

The migration configuration also requires at least two pgloader workers. With
one worker, tables larger than the prefetch queue can deadlock because the
reader fills the queue before a writer can run.

This was diagnosed in the original `pgload` proof of concept (now obsolete)
after early runs intermittently produced missing or short row counts. The
investigation ruled out FreeTDS, the network path, and the source data by
independently verifying source row counts through direct FreeTDS/`tsql`
queries and Microsoft `sqlcmd`, and by testing an isolated single-table load
(see `mssql-anschriften-only.load.template`) before re-testing the full
database. The root cause was the pgloader worker/concurrency deadlock
described above; `workers = 2`, `concurrency = 1`, and `prefetch rows = 1000`
(already used in `mssql-to-postgres.load.template`) resolved it.

This source patch is separate from the composite foreign-key workaround.
Pgloader's automatic foreign-key creation is disabled, and
`generate-postgres-fks.sh` recreates the foreign keys from SQL Server metadata
after the data has been copied.

### Configuration

Configure the source and target connections before running the migration.
The scripts and `.load` templates do not hardcode real credentials or
hostnames. Their connection parameters come from `.env` (excluded from Git)
or already-exported shell variables, which always take precedence over
`.env`. The system FreeTDS configuration must explicitly contain the chosen
SQL Server hostname.

```bash
cp .env-example .env
# edit .env with the real SQL Server host, credentials, and PostgreSQL
# credentials
```

Supported environment variables, also documented in `.env-example`:

```text
MSSQL_HOST
MSSQL_PORT
MSSQL_DB
MSSQL_USER
MSSQL_PASSWORD
MSSQL_FREETDS_ALIAS

PGHOST
PGPORT
PGDATABASE
PGUSER
PGPASSWORD

TIMEZONE_MISMATCH_ACTION
```

`TIMEZONE_MISMATCH_ACTION` (default `abort`) controls what
`run-pgloader-fullmigration.sh` does when the `check-timezones.sh` step it
runs after the foreign-key recreation finds a date/time mismatch between
SQL Server and PostgreSQL:

- `abort` — stop the migration and exit non-zero.
- `warn` — log a warning to the migration log and continue.
- `ignore` — skip the timezone check entirely.

Use one canonical hostname for the SQL Server throughout the migration
configuration. Set both `MSSQL_HOST` and `MSSQL_FREETDS_ALIAS` to that
hostname. The FreeTDS section name and its `host` value must use the same
hostname so pgloader, `sqlcmd`, and the helper scripts resolve the same
endpoint.

`run-pgloader-fullmigration.sh` renders `mssql-to-postgres.load.template`
into `mssql-to-postgres.load` via `envsubst` before invoking pgloader, and
that rendered file is Git-ignored. To render `mssql-anschriften-only.load.template`
manually for ad hoc use, see the comment at the top of that file.

Do not commit real database passwords, private hostnames, or customer data.

### FreeTDS

The migration host must be able to resolve the SQL Server by hostname. Use an
organization-managed DNS name where available. Otherwise, add a stable entry
to `/etc/hosts`:

```text
192.0.2.10 turista-sql.example.internal
```

Verify name resolution before configuring or running the migration:

```bash
getent hosts turista-sql.example.internal
```

Copy `freetds.conf.example` to `/etc/freetds/freetds.conf`. Use the resolved
hostname as both the FreeTDS section name and the `host` value:

```ini
[turista-sql.example.internal]
    host = turista-sql.example.internal
    port = 1433
    tds version = 7.4
    client charset = UTF-8
```

Use this same hostname in `.env`:

```dotenv
MSSQL_HOST=turista-sql.example.internal
MSSQL_FREETDS_ALIAS=turista-sql.example.internal
```

The generated `mssql-to-postgres.load` file then uses the same server name
through `MSSQL_FREETDS_ALIAS`. Do not mix an IP address, a short alias, and a
DNS name across these settings; inconsistent names make connection failures
and troubleshooting harder.

### Usage

Recommended migration procedure:

1. Choose one stable SQL Server hostname.
2. Ensure the hostname resolves through DNS or `/etc/hosts`.
3. Use that hostname as the FreeTDS section name and `host` value.
4. Set both `MSSQL_HOST` and `MSSQL_FREETDS_ALIAS` to the same hostname.
5. Configure the remaining SQL Server and PostgreSQL connection values.
6. Run the migration from the directory containing the migration files.

```bash
getent hosts turista-sql.example.internal

cp .env-example .env
# Edit .env. Use turista-sql.example.internal for both MSSQL_HOST and
# MSSQL_FREETDS_ALIAS, then set the credentials and PostgreSQL connection.

./run-pgloader-fullmigration.sh
```

The script performs the pgloader import, creates and applies the foreign keys,
and then runs the timezone check (`check-timezones.sh`); see
`TIMEZONE_MISMATCH_ACTION` under Configuration for how a mismatch is handled.
The final source-to-target comparison (`compare-table-counts.sh`) is currently
disabled in the script (commented out) and must be run independently, see
Validation below.

Passwords can also be entered interactively when requested by the helper
scripts if left out of `.env`.

### Validation

Run the comparison independently with:

```bash
./compare-table-counts.sh
```

For just the row counts (e.g. a quick sanity check of one side before the
other is ready), use:

```bash
./compare-table-counts.sh --db-mssql-only       # SQL Server row counts only
./compare-table-counts.sh --db-postgresql-only  # PostgreSQL row counts only
./compare-table-counts.sh --db-both             # row counts for both databases
```

`check-timezones.sh` (host clocks, column types, and migrated date/time
values) runs automatically as part of `run-pgloader-fullmigration.sh`. Run it
independently at any time with:

```bash
./check-timezones.sh
```

The report compares:

- Row counts for every table
- Primary keys
- Composite primary keys
- Foreign keys
- Composite foreign keys
- Disabled, untrusted, or unvalidated foreign keys
- Indexes
- Composite indexes
- SQL Server indexes containing included columns

Differences must be reviewed before the PostgreSQL database is used as a
trusted integration source.

## License and product names

The project is licensed under the GNU General Public License v3.0; see
`LICENSE`.

Turista and W&W are product or company names of their respective owners. This
project is an independent integration and migration utility and is not an
official W&W product.

## Limitations, exclusions, and drawbacks

- This project creates a point-in-time database copy. It does not provide
  continuous replication, change-data capture, or automatic synchronization.
- It does not provide a REST or GraphQL API. Such an API must be implemented
  and secured separately.
- It does not write PostgreSQL changes back to Turista.
- It does not replace the Turista application, its business logic, validation,
  permissions, workflows, or user interface.
- It does not automatically create a web application or native client for
  macOS, Linux, Android, iOS, smartphones, or tablets. These interfaces must be
  developed, deployed, and maintained separately.
- It does not automatically add cloud integration to Turista itself. It makes
  a PostgreSQL copy available as a foundation for separately implemented cloud
  integrations.
- It does not automatically provide customized lead-entry or customer-service
  interfaces, pre-fill Turista with customer data collected from websites or
  shops, or execute Turista business workflows.
- It does not implement bidirectional synchronization of offers, descriptions,
  pictures, documents, prices, availability, or other product content between
  Turista and external shops or websites. Such synchronization requires a
  separately designed integration, including field mapping, conflict
  resolution, validation, and ownership rules.
- Database-level access can expose implementation details that were not
  designed as a stable public interface. A future Turista update may change
  tables, columns, relationships, or data semantics.
- A technically successful migration does not guarantee that every source
  value has the expected business meaning in a consuming system.
- SQL Server and PostgreSQL differ in data types, collations, indexes,
  constraints, functions, and transaction behavior. Migration results must be
  validated for the intended workload.
- The current workflow can drop and recreate target objects. It is unsuitable
  for a PostgreSQL database containing unrelated or authoritative data.
- Running repeated full migrations may require downtime, substantial network
  bandwidth, storage, and processing time.
- Operating PostgreSQL in AWS, Google Cloud, Azure, Kubernetes, Docker, or
  Cloud Foundry still requires platform-specific architecture, networking,
  backup, monitoring, scaling, security, and cost management.
- Container orchestration does not by itself make a database highly available
  or durable. Production PostgreSQL needs suitable persistent storage,
  backups, recovery testing, and availability planning.
- Migrated data may include personal, financial, passport, or other sensitive
  information. The operator remains responsible for authorization, encryption,
  auditing, retention, deletion, and applicable data-protection obligations.
- This project is independent of W&W and is not an official or supported
  Turista integration interface.

## Further integration and migration support

If a one-time copy is not enough, I can help keep information up to date in
both Turista and connected systems. For example, a customer address changed in
a website, shop, CRM, or service application can be transferred back to
Turista, while changes made in Turista can be made available to the other
systems. This is called bidirectional synchronization.

The business benefit is that employees do not have to enter the same
information several times in different applications. This can reduce manual
work, outdated records, typing mistakes, and differences between sales,
service, accounting, websites, and shops. The exact rules remain under the
organization's control, including which system is allowed to change each type
of information.

I can also help with a complete move from Turista to an open-source ERP and CRM
system. Instead of only making Turista data easier to access, this replaces the
Windows-only application with a modern business platform for areas such as
customer management, sales, offers, orders, invoicing, and reporting. Depending
on the selected solution, employees can work through a web browser from
Windows, macOS, Linux, smartphones, and tablets.

Such a migration can reduce dependence on a closed application, avoid repeated
data entry, simplify connections to websites and cloud services, and provide
one shared source of information across departments. It also requires careful
planning of business processes, responsibilities, permissions, data quality,
training, and the transition period.

A ready-to-use migration from Turista to the open-source ERP and CRM system
ERPNext is available upon request.
