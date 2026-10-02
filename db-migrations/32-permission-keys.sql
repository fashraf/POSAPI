/*==============================================================================
  Nazad POS — 32 · Permission keys the role screen offers

  The role matrix (POSFO src/types/permissions.ts) lists thirteen keys that
  core.Permission did not have. Saving a role with any of them ticked was
  refused as "one of those permissions does not exist", so the matrix could
  not be saved as drawn. They are seeded here with the screen's sensitivity
  (none → 'general').

  The owner role holds every permission, so it gets all of them. pos.view —
  the key that shows the till in the menu — also goes to every role that can
  already ring up a sale; otherwise a cashier would lose the POS menu entry the
  day the menu is driven by server permissions. Everything else is left for
  the owner to grant from the roles screen.

  The reverse gap is not touched here: keys the server checks that the matrix
  does not list (customers.credit, discounts.approve, finance.commission,
  finance.commission_rules, finance.payroll, inventory.restock, kitchen.view,
  kitchen.update, pos.open_drawer, sales.refund, users.assign_branches,
  users.delete, users.override, vendors.pay, devices.discover) need adding on
  the frontend.
==============================================================================*/

USE POSMAIN;
GO

INSERT INTO core.Permission (PermissionKey, Module, Action, Sensitivity)
SELECT v.PermissionKey, v.Module, v.Action, v.Sensitivity
FROM (VALUES
    (N'branches.create',    N'branches',  N'create',         N'general'),
    (N'branches.edit',      N'branches',  N'edit',           N'general'),
    (N'branches.view',      N'branches',  N'view',           N'general'),
    (N'customers.delete',   N'customers', N'delete',         N'personal'),
    (N'inventory.stocktake',N'inventory', N'stocktake',      N'general'),
    (N'pos.override_price', N'pos',       N'override_price', N'financial'),
    (N'pos.return_sale',    N'pos',       N'return_sale',    N'financial'),
    (N'pos.view',           N'pos',       N'view',           N'general'),
    (N'pos.void_sale',      N'pos',       N'void_sale',      N'financial'),
    (N'reports.export',     N'reports',   N'export',         N'financial'),
    (N'sales.reprint',      N'sales',     N'reprint',        N'general'),
    (N'sales.return',       N'sales',     N'return',         N'financial'),
    (N'vendors.delete',     N'vendors',   N'delete',         N'general')
) AS v (PermissionKey, Module, Action, Sensitivity)
WHERE NOT EXISTS (SELECT 1 FROM core.Permission AS p WHERE p.PermissionKey = v.PermissionKey);
GO

/* The owner holds everything — including any key added after this file. */
INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT N'rol_owner', p.PermissionKey
FROM core.Permission AS p
WHERE EXISTS (SELECT 1 FROM core.Role WHERE RoleId = N'rol_owner')
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                  WHERE rp.RoleId = N'rol_owner' AND rp.PermissionKey = p.PermissionKey);
GO

INSERT INTO core.RolePermission (RoleId, PermissionKey)
SELECT rp.RoleId, N'pos.view'
FROM core.RolePermission AS rp
WHERE rp.PermissionKey = N'pos.create_sale'
  AND NOT EXISTS (SELECT 1 FROM core.RolePermission AS x
                  WHERE x.RoleId = rp.RoleId AND x.PermissionKey = N'pos.view');
GO

PRINT N'32 · Permission keys seeded.';
GO

SELECT
    CASE WHEN (SELECT COUNT(*) FROM core.Permission
               WHERE PermissionKey IN (N'pos.view', N'sales.return', N'vendors.delete',
                                       N'branches.view', N'reports.export')) < 5
              THEN N'FAIL  keys missing'
         WHEN EXISTS (SELECT 1 FROM core.Permission AS p
                      WHERE NOT EXISTS (SELECT 1 FROM core.RolePermission AS rp
                                        WHERE rp.RoleId = N'rol_owner' AND rp.PermissionKey = p.PermissionKey))
              THEN N'FAIL  owner is missing a permission'
         ELSE N'PASS  Permission keys ready'
    END AS Result;
GO
