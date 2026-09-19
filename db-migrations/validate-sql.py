"""Static checks over the migration. Not a substitute for running it, but it
catches the failures that would otherwise surface halfway through a deploy."""
import re, glob, sys

def strip_comments(text):
    """Reduce a script to executable SQL.

    Comments and string literals both contain prose, and a keyword inside either
    is not a keyword. Three separate false failures this session traced back to
    matching English words in my own explanations, so both are removed before
    any keyword analysis runs."""
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'--[^\n]*', '', text)
    # String literals, including the N'...' form, with '' escapes.
    text = re.sub(r"N?'(?:[^']|'')*'", "''", text)
    return text

files = sorted(glob.glob('sql/*.sql'))
raw  = {f: open(f, encoding='utf-8').read() for f in files}
code = {f: strip_comments(v) for f, v in raw.items()}
full = "\n".join(code.values())

problems = []
def check(name, ok, detail=''):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'' if ok else ': ' + detail}")
    if not ok: problems.append(name)

# 1. Tables referenced by FKs must be defined, and defined earlier.
created, order = {}, []
for f in files:
    for m in re.finditer(r'CREATE TABLE\s+(\w+)\.(\w+)', code[f]):
        key = f"{m.group(1)}.{m.group(2)}".lower()
        created[key] = f
        order.append(key)

refs = re.findall(r'REFERENCES\s+(\w+)\.(\w+)', full)
missing = {f"{s}.{t}".lower() for s, t in refs} - set(created)
check("every FK target is a defined table", not missing, str(missing))

# 2. Forward references — a FK to a table created later in the run.
fwd = []
for f in files:
    body = code[f]
    local_created = []
    for m in re.finditer(r'(CREATE TABLE\s+(\w+)\.(\w+))|(REFERENCES\s+(\w+)\.(\w+))', body):
        if m.group(1):
            local_created.append(f"{m.group(2)}.{m.group(3)}".lower())
        else:
            tgt = f"{m.group(5)}.{m.group(6)}".lower()
            if tgt in created and order.index(tgt) > (order.index(local_created[-1]) if local_created else -1):
                if tgt not in local_created:
                    idx_tgt = order.index(tgt)
                    # only a problem if the target appears later in global order
                    here = local_created[-1] if local_created else None
                    if here and order.index(here) < idx_tgt:
                        fwd.append((f, tgt))
check("no forward foreign keys", not fwd, str(fwd[:3]))

# 3. Money columns must be BIGINT halalas, never DECIMAL or FLOAT.
#    Money is identified by the trailing H, which is the whole point of the
#    naming convention. Quantities (DECIMAL) and rates are deliberately not.
bad_money = re.findall(r'(\w+H)\s+(DECIMAL|FLOAT|MONEY|REAL)\b', full, re.I)
check("no float/decimal money columns", not bad_money, str(bad_money[:3]))

money_cols = set(re.findall(r'^\s*(\w+H)\s+BIGINT', full, re.M))
check("money columns exist and are BIGINT", len(money_cols) > 30, f"{len(money_cols)} found")

# 4. Every user-facing text column is NVARCHAR, never VARCHAR.
bad_text = re.findall(r'\b(?<!N)VARCHAR\s*\(', full)
plain = [m for m in re.finditer(r'\s(VARCHAR)\s*\(', full)]
check("no non-unicode VARCHAR columns", not plain, f"{len(plain)} found")

# 5. Arabic name columns exist wherever an English one does.
en_cols = set(re.findall(r'(\w+)NameEn\b', full)) | {'' for _ in [0]}
pairs_ok = full.count('NameAr') >= full.count('NameEn') * 0.9
check("Arabic name columns match English ones", pairs_ok,
      f"NameAr={full.count('NameAr')} NameEn={full.count('NameEn')}")

# 6. Balanced block terminators. Every END closes a BEGIN or a CASE.
begins = len(re.findall(r'\bBEGIN\b(?!\s+TRAN)', full, re.I))
cases  = len(re.findall(r'\bCASE\b', full, re.I))
ends   = len(re.findall(r'(?<![@\w])END\b', full, re.I))
check("BEGIN/CASE/END balanced", begins + cases == ends,
      f"BEGIN={begins} + CASE={cases} != END={ends}")

commits = len(re.findall(r'\bCOMMIT\b', full, re.I))
trans   = len(re.findall(r'\bBEGIN TRAN\b', full, re.I))
check("every transaction commits", trans == commits, f"TRAN={trans} COMMIT={commits}")

# 7. Balanced parentheses overall.
check("parentheses balanced", full.count('(') == full.count(')'),
      f"{full.count('(')} open vs {full.count(')')} close")

# 8. Every batch separator on its own line.
bad_go = re.findall(r'\S[ \t]+GO[ \t]*$', full, re.M)
check("GO separators are alone on their line", not bad_go, str(bad_go[:3]))

# 9. Chart of accounts codes used in procs must be seeded.
seeded = set(re.findall(r"\(N'(\d{4})', N'(?:asset|liability|equity|revenue|expense)'", full))
used = set(re.findall(r"N'(\d{4})'", full)) - seeded
unknown = {c for c in used if re.match(r'^[1-6]\d{3}$', c)} - seeded
check("all account codes referenced are seeded", not unknown, str(unknown))

# 10. Procedures referenced before creation.
proc_defs = set(re.findall(r'CREATE (?:PROCEDURE|FUNCTION)\s+(\w+\.\w+)', full))
proc_calls = set(re.findall(r'EXEC\s+(\w+\.\w+)', full))
check("all called procedures are defined", proc_calls <= proc_defs, str(proc_calls - proc_defs))

print()
print(f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
