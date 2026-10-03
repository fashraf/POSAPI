# Database migrations

Run `apply-migrations.cmd` from the POSAPI folder. It creates `POSMAIN` if it is missing, runs every file it has not run before, and records each one in `dbo.SchemaMigration`.

| File | What it is | When it runs |
|---|---|---|
| `001-baseline-schema.sql` | The whole schema | Once, on a new database |
| `002-reference-data.sql` | Languages, chart of accounts, permissions, roles and grants, default expense categories, default customer bill | Once, on a new database |
| `003`–`899` | Later changes | Once each, in order |
| `900-demo-data.sql` | Demo company, branches, staff (password `1234`), catalog, six months of history | Only with `--demo`, on a database the same run creates |
| `999-verify-install.sql` | Read-only health check | After every run |

## Common runs

```
apply-migrations.cmd                                   Windows login, .\SQLEXPRESS
apply-migrations.cmd -S VMI1342014\SQLEXPRESS --dry-run
apply-migrations.cmd -S 127.0.0.1,1433 -U sa -P "..." --recreate --demo
```

- `--dry-run` lists what would run and changes nothing.
- `--adopt` is for a database built by the old migration files (11–43, replaced by 001 and 002 on 2026-10-03). If that database has all of them applied, its schema already matches 001, and the script records 001 and 002 without running them. It refuses a database that stopped part-way.
- `--recreate` drops `POSMAIN` and builds it again. It asks you to type `POSMAIN` first unless you pass `--yes`.

## Adding a change

1. Create the next number after the last one, e.g. `003-loyalty-points.sql`. Never edit a file that has already run anywhere: its name is recorded, and editing it changes nothing on databases that already ran it.
2. Start with `USE POSMAIN;` and `GO`.
3. Make it safe to run twice (`CREATE OR ALTER`, `IF COL_LENGTH(...) IS NULL`, `IF NOT EXISTS`). The runner only runs it once, but someone will run it by hand.
4. In T-SQL, the statement before a `THROW` must end with `;`.
5. Try it with `--dry-run`, then apply it.

`sqlcmd` reads these files as UTF-8 (`-f 65001` in the runner). Run a file by hand the same way, or its Arabic text is stored garbled:

```
sqlcmd -S .\SQLEXPRESS -E -b -I -C -f 65001 -i 003-loyalty-points.sql
```

The old files are in git history, before the commit that added this README.
