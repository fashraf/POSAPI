namespace PosApi.Auth;

/// <summary>
/// How signing in works.
///
/// Two-step is the real design: an OTP proves the person holds the address or
/// number, which a password alone does not. Single-step exists so development
/// does not need an SMS provider — it still checks a real password hash, so it
/// is a shortcut around the second factor, not around authentication.
/// </summary>
public enum LoginMode
{
    /// <summary>login -> challenge -> verify -> tokens. The production flow.</summary>
    TwoStep = 0,

    /// <summary>login -> tokens, on a verified password. Development only.</summary>
    SinglePassword = 1
}

public sealed class AuthOptions
{
    public const string SectionName = "Auth";

    /// <summary>
    /// Defaults to TwoStep, so a configuration file that says nothing gets the
    /// safer flow. Single-step has to be asked for explicitly.
    /// </summary>
    public LoginMode LoginMode { get; init; } = LoginMode.TwoStep;

    public int OtpLength { get; init; } = 4;
    public int OtpValidMinutes { get; init; } = 5;
    public int OtpMaxAttempts { get; init; } = 5;
    public int MaxFailedLogins { get; init; } = 5;
    public int LockoutMinutes { get; init; } = 15;

    /// <summary>
    /// Accept a fixed OTP instead of generating one, so the app is usable
    /// before an SMS provider is wired up.
    ///
    /// This is an authentication bypass. Program.cs refuses to start if it is
    /// true outside Development — a config file copied to production by mistake
    /// should fail loudly at boot rather than silently let anyone in.
    /// </summary>
    public bool UseFixedDevOtp { get; init; }

    public string FixedDevOtp { get; init; } = "1234";
}

public sealed class JwtOptions
{
    public const string SectionName = "Jwt";

    public string Issuer { get; init; } = "nazad-pos";
    public string Audience { get; init; } = "nazad-pos-clients";
    public int AccessTokenMinutes { get; init; } = 30;
    public int RefreshTokenDays { get; init; } = 14;

    /// <summary>
    /// Never in appsettings.json. User-secrets in development, an environment
    /// variable in production. A signing key in source control is a signing key
    /// an attacker can mint their own tokens with.
    /// </summary>
    public string SigningKey { get; init; } = string.Empty;
}
