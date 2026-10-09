# Control database and tenants

Nazad POS is multi-tenant, with one database per tenant:

| Database | What is in it | Built from |
|---|---|---|
| `POSCONTROL` | Tenants, plans, features, subscriptions, invoices, support issues, platform administrators, the console's audit log, the login directory and the hardware register. It holds no sales, stock or staff data. | `db-control/` |
| `POS_CL00002`, `POS_CL00003`, … | One tenant's business: sales, catalog, staff, finance. | `db-migrations/` (001–899) |
| `POSMAIN` | The database from before tenancy, adopted as tenant `CL-00001`. | already exists |

The API does all of this itself. You do not need to run any script.

- **At startup** it creates `POSCONTROL` if it is missing and applies `db-control/` files (tracked in `POSCONTROL.dbo.SchemaMigration`). It creates the first administrator from `SuperAdmin:Mobile` / `SuperAdmin:Password` when there is none, and adopts `Tenancy:AdoptDatabase` (default `POSMAIN`) as the first tenant.
- **Then, in the background**, every tenant database receives any `db-migrations/` file it has not run. The console can trigger the same thing: Platform → `POST /api/superadmin/platform/migrate`.
- **Creating a client** (console wizard, or POS self sign-up) creates `POS_CL<number>`, runs `db-migrations/` 001–899 against it, registers the business and owner inside it, opens the subscription and records the owner in the login directory. If any step fails, the database is dropped and the control rows removed.

## Configuration

```jsonc
"ConnectionStrings": {
  "PosMain": "...",        // server used for both, when the two below are absent
  "Control": "...",        // optional: the control database itself
  "TenantServer": "..."    // optional: the server where tenant databases are created
},
"Tenancy": {
  "ControlDatabase": "POSCONTROL",
  "TenantDatabasePrefix": "POS_",
  "AdoptDatabase": "POSMAIN",
  "MigrateTenantsOnStartup": true,
  "SnapshotMinutes": 15
},
"SuperAdmin": { "Mobile": "05…", "Password": "…", "Name": "Platform admin" }  // user-secrets / environment in production
```

The SQL login needs permission to create databases (`dbcreator`) on the tenant server.

## How a request finds its tenant

- **Signed-in POS calls:** the token carries `tid`. `TenantMiddleware` reads the tenant from the control database (cached for 30 seconds) and refuses with 403 if the tenant is suspended, or its subscription is cancelled or expired.
- **Sign-in:** `ctl.LoginDirectory` maps every user's email, mobile and username to their tenant. These identifiers are therefore unique across the platform.
- **OTP challenges, refresh tokens and device tokens** start with the tenant id (`CL-00002.…`). The anonymous call that returns one can then find the tenant's database. The value is still verified inside that database.
- **Device registration codes** are recorded in `ctl.DeviceCode`. Discovery announcements are matched by serial number against the hardware register (`ctl.HardwareDevice`).

## Adding a control migration

Use the next free number, e.g. `003-…sql`. Start it with `USE POSCONTROL;` (the configured name replaces it) and make it safe to run twice.
