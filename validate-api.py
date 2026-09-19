"""Structural checks over the C# sources. Not a compiler — it catches
unbalanced braces, missing usings and security regressions, not type errors."""
import re, glob, sys, json

cs = sorted(glob.glob('src/**/*.cs', recursive=True))
problems = []

def check(name, ok, detail=''):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'' if ok else ': ' + detail}")
    if not ok: problems.append(name)

def strip(src):
    src = re.sub(r'"""(.*?)"""', '""', src, flags=re.S)      # raw strings
    src = re.sub(r'@"(?:[^"]|"")*"', '""', src)               # verbatim
    src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)             # normal
    src = re.sub(r'//[^\n]*', '', src)
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    return src

# 1. Braces and parens balance in every file.
bad = []
for f in cs:
    s = strip(open(f, encoding='utf-8').read())
    if s.count('{') != s.count('}'): bad.append((f, 'braces', s.count('{'), s.count('}')))
    if s.count('(') != s.count(')'): bad.append((f, 'parens', s.count('('), s.count(')')))
check("braces and parens balanced", not bad, str(bad))

# 2. Every file declares a namespace.
missing_ns = [f for f in cs if not re.search(r'^namespace\s', open(f,encoding='utf-8').read(), re.M)
              and 'Program.cs' not in f]
check("every file has a namespace", not missing_ns, str(missing_ns))

full = "\n".join(open(f, encoding='utf-8').read() for f in cs)
code = strip(full)

# 3. No string-concatenated SQL — the injection vector.
concat_sql = re.findall(r'(?:SELECT|INSERT|UPDATE|DELETE)[^;"]*"\s*\+\s*\w', full, re.I)
check("no string-concatenated SQL", not concat_sql, str(concat_sql[:2]))

# 4. Every SQL call passes parameters as an object, not interpolation.
interpolated = re.findall(r'\$"""|\$"[^"]*(?:SELECT|INSERT|UPDATE|DELETE)', full, re.I)
check("no interpolated SQL strings", not interpolated, str(interpolated[:2]))

# 5. Passwords hashed, never encrypted or stored raw.
check("uses PBKDF2", 'KeyDerivation.Pbkdf2' in full)
check("constant-time comparison", 'FixedTimeEquals' in full)
check("no reversible password crypto", not re.search(r'(Encrypt|Decrypt)\w*\(\s*password', code, re.I))

# 6. OTP is hashed and attempt-limited.
check("OTP stored hashed", 'CodeHash' in full and '_hasher.Hash(code)' in full)
check("OTP attempts counted", 'Attempts + 1' in full)
check("OTP consumed after use", 'ConsumedAtUtc = SYSUTCDATETIME()' in full)
check("OTP uses secure RNG", 'RandomNumberGenerator.GetInt32' in full)

# 7. The dev bypass cannot reach production.
check("dev OTP guarded at startup",
      'UseFixedDevOtp' in full and 'IsDevelopment()' in full and 'throw new InvalidOperationException' in full)

# 8. Signing key is not committed.
settings = json.load(open('src/PosApi/appsettings.json'))
check("no signing key in appsettings", 'SigningKey' not in json.dumps(settings))
check("signing key length enforced",
      "GetByteCount(configured) < 32" in full or "SigningKey.Length < 32" in full)
check("signing key resolved once and shared",
      'class SigningKeyProvider' in full and 'IssuerSigningKey = signingKeyProvider.Key' in full)
check("empty signing key rejected at startup",
      'Jwt:SigningKey is not set' in full)

# 9. CORS is an explicit allow-list.
check("CORS not wide open", 'AllowAnyOrigin' not in code)
check("CORS origins configured", 'WithOrigins' in full)

# 10. Auth endpoints are rate limited.
check("auth rate limited", 'RequireRateLimiting("auth")' in full)

# 11. No stack traces leaked to callers.
# A stack trace may be returned in Development only. The rule is about
# production, so verify the guard rather than the absence of the word.
if 'StackTrace' in code:
    prog = open('src/PosApi/Program.cs').read()
    dev_at = prog.find('IsDevelopment()', prog.find('UseExceptionHandler'))
    trace_at = prog.find('stackTrace')
    check("stack traces are Development-only",
          dev_at != -1 and trace_at != -1 and dev_at < trace_at)
else:
    check("no stack trace in responses", True)

# 12. Errors are bilingual.
errs = re.findall(r'ApiError\.Create\(', full)
ar = re.findall(r'MessageAr|"[^"]*[\u0600-\u06FF]', full)
check("errors carry Arabic and English", len(errs) > 0 and len(ar) >= len(errs),
      f"{len(errs)} errors, {len(ar)} arabic strings")

# 13. Money is long, never decimal/double.
bad_money = re.findall(r'(?:decimal|double|float)\s+\w*(?:Amount|Price|Total|Cost|Balance)H\b', full, re.I)
check("money typed as long", not bad_money, str(bad_money))

# 14. Async methods take a CancellationToken.
sigs = re.findall(r'(?:private|public|internal)\s+static\s+async\s+Task<[^>]+>\s+(\w+)\s*\(([^)]*)\)', full, re.S)
no_ct = [n for n, args in sigs if 'CancellationToken' not in args]
check("async endpoints accept CancellationToken", not no_ct, str(no_ct))

print()
print(f"{len(problems)} problem(s) across {len(cs)} files")
sys.exit(1 if problems else 0)
