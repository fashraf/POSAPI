# Phase D3 — cumulative differential VAT for partial credit notes (2026-09-27)

🔴 Money / tax. Owner-approved accounting rule change, recorded in `docs/OWNER_REQUESTS.md` E7 and
`docs/spec/TAX_RULES.md` §1.5 (the dated box). It supersedes per-document independent VAT rounding
for partial credit notes. Offline throughout: nothing contacted the authority or production.

## The rule, as implemented

For each line of the original tax invoice (Q its quantity, V its stated VAT, R_k the refunded
quantity after note k): `share(r) = Rounding.scale(V, r, Q)`; the note's VAT on that line is
`share(R_k) − share(R_{k−1})`; its taxable amount is the differential line money less that VAT.

- `nazad-lite/core/src/main/kotlin/sa/nazad/core/tax/CreditNoteTax.kt` — the rule (one rounding function).
- `DocumentTax.computeFromStatedLines` — a note's totals from stated line VAT; every engine invariant re-checked.
- `StoredDocuments.writeTaxCreditNote` — inside the note's one transaction: V derived from the original's
  stored lines by the engine that issued it and held to the original's stored tax; the VAT the stored notes
  already took must equal the rule's figure from the stored refunded quantities (no new column, no migration);
  a part whose VAT step exceeds its money is refused `PART_TOO_SMALL`, nothing written.

## Worked example — one kilogram at 10.50, VAT 1.37 (V = 137, Q = 1000)

share(r) = round(137 × r / 1000): share(1) = 0, share(333) = 46, share(334) = 46, share(666) = 91,
share(667) = 91, share(999) = 137, share(1000) = 137.

| order | part | money (differential) | VAT = share(R_k) − share(R_{k−1}) | taxable |
|---|---|---|---|---|
| 333 first | 0.333 | 3.50 | 46 − 0 = 0.46 | 3.04 |
| | 0.333 | 3.49 | 91 − 46 = 0.45 | 3.04 |
| | 0.333 | 3.50 | 137 − 91 = 0.46 | 3.04 |
| | 0.001 | 0.01 | 137 − 137 = 0.00 | 0.01 |
| | **total** | **10.50** | **1.37** | **9.13** |
| 1 first | 0.001 | 0.01 | 0 − 0 = 0.00 | 0.01 |
| | 0.333 | 3.50 | 46 − 0 = 0.46 | 3.04 |
| | 0.333 | 3.49 | 91 − 46 = 0.45 | 3.04 |
| | 0.333 | 3.50 | 137 − 91 = 0.46 | 3.04 |
| | **total** | **10.50** | **1.37** | **9.13** |

Before (Phase D2, each note computing its own VAT): 0.46, 0.46, 0.46, 0.00 = 1.38 against 1.37 charged.

## Evidence (each re-runnable)

| file | what | result |
|---|---|---|
| `verify.log` | `./scripts/verify.sh` | exit 0, `tests=599 failures=0 skipped=0` |
| `CreditNoteTaxTest` (in verify) | worked examples; 1,000 one-gram parts at four prices; share exact/monotone; refusals; property over 4,000 random invoices (1–6 lines, standard and zero-rated) | 18,051 notes, 3 refused (all sub-halala parts), 0 stuck; worst BR-CO-17 deviation 0.02 on one line (3 notes), 0.01 on every one-line invoice |
| `validate-chains.sh` → `validator-chains.log`, `chains/*/*.validation.txt` | the authority's validator (SDK 3.4.8) over chains the **real door** wrote (`TaxIssuingTest`): `order-333`, `order-1`, `mixed` | **15 of 15 PASSED**; negative controls FAILED as they must; one document with warnings (below) |
| `figures.sh` → `figures.log` | the taxable / VAT / payable each signed document states | as the table above; `mixed` gives back 37.91 VAT and 290.68 exactly |
| `device-run.sh` → `instrumented-phase-d3.log`, `device/`, `validator-device-chain.log` | emulator-5554 (API 25) at commit ef861a2, clean tree: every instrumented test listed (5) and run, the tax path in two processes; after the restart the terminal issues the 10.50 × (0.333, 0.333, 0.333, 0.001) chain on its keystore key; pulled and validated | 4 of 4 runs OK; device reports `sdk=25 documents=9 icv=[1..9] partialVat=[0.46, 0.45, 0.46, 0.00] partialPayable=[3.50, 3.49, 3.50, 0.01]`; validator **9 of 9 PASSED**, no warnings; both negative controls FAILED as they must |

Warnings, verbatim, `chains/mixed/03-credit-note.xml` (taxable 232.57, VAT 34.87; 232.57 × 15% = 34.89):

```
[WARN] ValidationProcessorImpl - CODE : BR-CO-17, MESSAGE : [BR-CO-17]-VAT category tax amount (BT-117) = VAT category taxable amount (BT-116) x (VAT category rate (BT-119) / 100), rounded to two decimals.
[WARN] ValidationProcessorImpl - CODE : BR-S-09, MESSAGE : [BR-S-09]-The VAT category tax amount (BT-117) in a VAT breakdown (BG-23) where VAT category code (BT-118) is "Standard rated" shall equal the VAT category taxable amount (BT-116) multiplied by the VAT category rate (BT-119) / 100), rounded to two decimals.
*** GLOBAL VALIDATION RESULT = PASSED
```

## Raised, not decided here (OWNER_REQUESTS E7.2, E7.3)

1. Taxable ≥ 0 cannot hold for a part worth under about one halala before tax; such a note is refused
   `PART_TOO_SMALL` (new refusal; English and Arabic sentence await the owner's wording approval).
2. "BR-CO-17 deviation ≤ 0.01 per line" fails in rare multi-line cases (0.02); the authority's validator
   reports warnings and PASSES.
3. The D2 experiment code was removed (superseded); its evidence stays, with a pointer to this rule.
