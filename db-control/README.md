# Control database and tenants

Nazad POS is multi-tenant, with one PostgreSQL database per tenant:

| Database | What is in it | Built from |
|---|---|---|
| `poscontrol` | Tenants, plans, features, subscriptions, invoices, support issues, platform administrators, the console's audit log, the login directory and the hardware register. It holds no sales, stock or staff data. | `db-control/` |
| `pos_cl00002`, `pos_cl00003`, … | One tenant's business: sales, catalog, staff, finance. | `db-migrations/` (001–899) |
| `posmain` | A database built by `apply-migrations.sh` / `.cmd` (the demo, or a single-business install), adopted as tenant `CL-00001`. | `db-migrations/` |

Database names are lower case. PostgreSQL folds an unquoted name to lower case when it creates a database, but a connection string must name it exactly, so the API lower-cases every name it builds or reads from configuration.

The API does all of this itself. You do not need to run any script.

- **At startup** it creates `poscontrol` if it is missing (`ENCODING 'UTF8' TEMPLATE template0`) and applies the `db-control/` files it has not run, each in its own transaction, recorded in `poscontrol`'s `dbo.SchemaMigration`. If the control database cannot be reached, the API does not start. It creates the first administrator from `SuperAdmin:Mobile` / `SuperAdmin:Password` when there is none, and adopts `Tenancy:AdoptDatabase` (default `posmain`) as the first tenant when that database exists and was built by the migrations.
- **Then, in the background**, every tenant database receives any `db-migrations/` file it has not run. The console can trigger the same thing: Platform → `POST /api/superadmin/platform/migrate`.
- **Creating a client** (console wizard, or POS self sign-up) creates `pos_cl<number>`, runs `db-migrations/` 001–899 against it, registers the business and owner inside it, opens the subscription and records the owner in the login directory. If any step fails, the database is dropped (`DROP DATABASE … WITH (FORCE)`) and the control rows removed.

## Configuration

Connection strings are in Npgsql format. Only the server and login of `PosMain` (or `TenantServer`) are used: the API reaches the control and tenant databases there under their own names, whatever `Database` says.

```jsonc
"ConnectionStrings": {
  "PosMain": "Host=localhost;Port=5432;Database=posmain;Username=pos;Password=...",  // server used for both, when the two below are absent
  "Control": "Host=...;Port=5432;Database=poscontrol;Username=...;Password=...",    // optional: the control database itself
  "TenantServer": "Host=...;Port=5432;Username=...;Password=..."                    // optional: the server where tenant databases are created
},
"Tenancy": {
  "ControlDatabase": "poscontrol",
  "TenantDatabasePrefix": "pos_",
  "AdoptDatabase": "posmain",
  "MigrateTenantsOnStartup": true,
  "SnapshotMinutes": 15
},
"SuperAdmin": { "Mobile": "05…", "Password": "…", "Name": "Platform admin" }  // user-secrets / environment in production
```

The API adds `Timezone=UTC` and `Include Error Detail=true` to every connection itself; do not override them. To create databases it connects to the server's `postgres` database.

The role needs permission to create databases on the tenant server (and on the control server, the first time):

```sql
CREATE ROLE pos LOGIN PASSWORD '...' CREATEDB;
```

It owns every database it creates, so it needs nothing else there. Tenant and control databases use the ICU collation `ci` that their first migration creates, so the server must be built with ICU (the official PostgreSQL packages and Docker images are).

## How a request finds its tenant

- **Signed-in POS calls:** the token carries `tid`. `TenantMiddleware` reads the tenant from the control database (cached for 30 seconds) and refuses with 403 if the tenant is suspended, or its subscription is cancelled or expired.
- **Sign-in:** `ctl.LoginDirectory` maps every user's email, mobile and username to their tenant. These identifiers are therefore unique across the platform.
- **OTP challenges, refresh tokens and device tokens** start with the tenant id (`CL-00002.…`). The anonymous call that returns one can then find the tenant's database. The value is still verified inside that database.
- **Device registration codes** are recorded in `ctl.DeviceCode`. Discovery announcements are matched by serial number against the hardware register (`ctl.HardwareDevice`).

## Adding a control migration

Use the next free number, e.g. `003-…sql`. Do not name the database (the API connects to the configured one; PostgreSQL has no `USE`), follow the conventions in `db-migrations/README.md`, and make the file safe to run twice (`CREATE OR REPLACE`, `IF NOT EXISTS`, `ON CONFLICT DO NOTHING`). Never edit a file that has already run anywhere: its name is recorded, and the edit would reach no existing database.
