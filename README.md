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

### Included scripts

- `run-pgloader-fullmigration.sh` runs the complete migration and validation.
- `mssql-to-postgres.load` defines the pgloader database migration.
- `generate-postgres-fks.sh` generates PostgreSQL foreign-key DDL from SQL
  Server metadata.
- `compare-table-counts.sh` compares row counts, keys, foreign keys, indexes,
  and referential-integrity metadata.
- `postgres-fks.sql` is generated during the migration and then applied to
  PostgreSQL.

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

This source patch is separate from the composite foreign-key workaround.
Pgloader's automatic foreign-key creation is disabled, and
`generate-postgres-fks.sh` recreates the foreign keys from SQL Server metadata
after the data has been copied.

### Configuration

Configure the source and target connections before running the migration.
Connection parameters should be supplied through environment variables or a
local configuration file that is excluded from Git.

Supported environment variables used by the helper scripts include:

```text
MSSQL_HOST
MSSQL_PORT
MSSQL_DB
MSSQL_USER
MSSQL_PASSWORD

PGHOST
PGPORT
PGDATABASE
PGUSER
PGPASSWORD
```

The pgloader connection strings in `mssql-to-postgres.load` must point to the
same source and target databases.

Do not commit real database passwords, private hostnames, or customer data.

### FreeTDS

The migration expects FreeTDS to resolve and connect to the SQL Server. A
typical `/etc/freetds/freetds.conf` entry looks like:

```ini
[turista]
    host = sql-server.example.internal
    port = 1433
    tds version = 7.4
    client charset = UTF-8
```

Use the matching server name in the pgloader SQL Server connection string.

### Usage

Run the scripts from the directory containing the migration files.

First export the connection settings:

```bash
export MSSQL_HOST="sql-server.example.internal"
export MSSQL_PORT="1433"
export MSSQL_DB="Turista"
export MSSQL_USER="pgloader_user"
export MSSQL_PASSWORD="your-sql-server-password"

export PGHOST="127.0.0.1"
export PGPORT="5432"
export PGDATABASE="turista"
export PGUSER="turista_pgloader"
export PGPASSWORD="your-postgresql-password"
```

Then run:

```bash
./run-pgloader-fullmigration.sh
```

The script performs the pgloader import, creates and applies the foreign keys,
and finally runs the source-to-target comparison.

Passwords can also be entered interactively when requested by the helper
scripts. The pgloader load file must still be configured securely for its own
database connections.

### Validation

Run the comparison independently with:

```bash
./compare-table-counts.sh
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

## Important operational notes

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

- ERP and CRM migrations
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
