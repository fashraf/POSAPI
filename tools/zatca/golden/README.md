# ZATCA golden invoices

Signed invoices and credit notes from the Nazad ZATCA developer kit
(`04-sample-invoices`, built and validated in Sept 2026). Each folder is one
chain in issue order. They are the reference our C# signer must match. They
are signed with a self-signed **test** certificate (`Test Store 01`), never
a real CSID.

| Folder / file | What it is |
|---|---|
| `single-simplified.xml` | One simplified invoice (388) |
| `chain-with-credit-note/` | Invoice, invoice, credit note (381), then an invoice issued after an app restart |
| `partial-return-order-333/`, `partial-return-order-1/`, `partial-return-mixed/` | One invoice and four partial credit notes each, using the cumulative VAT rule in `partial-return-RULE.md` |

Check them, or anything we generate, with ZATCA's own validator:

```
tools/zatca/validate-chain.sh tools/zatca/golden/chain-with-credit-note
```

Every file passes (measured 2026-11-18 with the .NET SDK 3.4.8). The only
expected warnings are BR-KSA-98 (the script hides it) and BR-CO-17 / BR-S-09
on `partial-return-mixed/03-credit-note.xml`, which the rule file explains.
