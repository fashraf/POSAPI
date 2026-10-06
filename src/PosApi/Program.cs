using System.IdentityModel.Tokens.Jwt;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Diagnostics;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.IdentityModel.Tokens;
using Microsoft.OpenApi.Models;
using PosApi.Audit;
using PosApi.Auth;
using PosApi.Common;
using PosApi.Data;
using PosApi.Features.Access;
using PosApi.Features.Catalog;
using PosApi.Features.Devices;
using PosApi.Features.Finance;
using PosApi.Features.Sales;
using PosApi.Features.Settings;
using PosApi.Localization;
using Serilog;

/*==============================================================================
  Nazad POS API — startup

  All of startup runs inside a try/catch that logs and reports. Without it,
  anything thrown while the host is being built disappears: Serilog has already
  replaced the default console logger by that point, and a Serilog with no sink
  makes the process exit in silence.
==============================================================================*/

/*
 * A bootstrap logger, before any configuration is read.
 *
 * UseSerilog replaces the default logging pipeline, so between that call and
 * the sinks being configured there is a window where log output goes nowhere.
 * An exception thrown in that window is invisible. This writes to the console
 * from the first line of the program, so no such window exists.
 */
Log.Logger = new LoggerConfiguration()
    .MinimumLevel.Information()
    .WriteTo.Console()
    .CreateBootstrapLogger();

try
{
    Log.Information("Starting Nazad POS API...");

    var builder = WebApplication.CreateBuilder(args);

    /*
     * Read Serilog's settings from configuration, but always keep a console
     * sink whatever that configuration says.
     *
     * WriteTo.Console() here is not a duplicate of any appsettings entry — it is
     * the guarantee. A Serilog section with no WriteTo array produces a logger
     * with zero sinks, and a logger with zero sinks is indistinguishable from a
     * dead process: no "Now listening on", no errors, nothing at all.
     */
    builder.Host.UseSerilog((context, services, configuration) => configuration
        .ReadFrom.Configuration(context.Configuration)
        .ReadFrom.Services(services)
        .Enrich.FromLogContext()
        .WriteTo.Console(
            outputTemplate:
            "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}"));

    /*
     * Validate the container while building it, in Development.
     *
     * A registration that cannot be constructed then fails at startup, by name,
     * rather than as a 500 the first time an endpoint happens to need it.
     */
    builder.Host.UseDefaultServiceProvider((context, options) =>
    {
        options.ValidateScopes = context.HostingEnvironment.IsDevelopment();
        options.ValidateOnBuild = context.HostingEnvironment.IsDevelopment();
    });

    /*------------------------------------------------------------------ URLs */

    /*
     * Bind explicitly when nothing else has.
     *
     * launchSettings.json applies only to `dotnet run` from the project folder.
     * Run the published output, or pass --no-launch-profile, and without this
     * the app binds a port chosen for it — which is how "it started but nothing
     * answers on 5001" happens.
     */
    if (string.IsNullOrWhiteSpace(builder.Configuration["urls"]) &&
        string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable("ASPNETCORE_URLS")))
    {
        builder.WebHost.UseUrls("http://localhost:5001");
    }

    /*--------------------------------------------------------------- options */

    builder.Services.Configure<AuthOptions>(
        builder.Configuration.GetSection(AuthOptions.SectionName));
    builder.Services.Configure<JwtOptions>(
        builder.Configuration.GetSection(JwtOptions.SectionName));

    var jwt = builder.Configuration.GetSection(JwtOptions.SectionName).Get<JwtOptions>()
              ?? new JwtOptions();
    var auth = builder.Configuration.GetSection(AuthOptions.SectionName).Get<AuthOptions>()
               ?? new AuthOptions();

    /*
     * Stamp the running build.
     *
     * "Did my change deploy?" has cost several rounds of debugging a fix that
     * was already written but never rebuilt. The assembly's write time answers
     * it in one line: if it predates the edit, the binary is stale whatever the
     * source says.
     */
    var assemblyPath = System.Reflection.Assembly.GetExecutingAssembly().Location;
    var builtAtUtc = string.IsNullOrEmpty(assemblyPath)
        ? (DateTime?)null
        : File.GetLastWriteTimeUtc(assemblyPath);

    Log.Information("Build compiled at: {BuiltAt:yyyy-MM-dd HH:mm:ss} UTC",
        builtAtUtc ?? DateTime.MinValue);
    Log.Information("Environment: {Environment}", builder.Environment.EnvironmentName);
    Log.Information("Login mode:  {LoginMode}", auth.LoginMode);

    /*
     * The development OTP is an authentication bypass: it lets anyone who knows
     * the fixed code sign in as anybody. Refusing to start is deliberate — a
     * config file copied to production should be a loud crash at boot, not a
     * quiet hole nobody notices until it is used.
     */
    if (auth.UseFixedDevOtp && !builder.Environment.IsDevelopment())
    {
        throw new InvalidOperationException(
            $"Auth:UseFixedDevOtp is enabled in the '{builder.Environment.EnvironmentName}' " +
            "environment. This bypasses authentication entirely and is only permitted in " +
            "Development. Remove it from configuration before deploying.");
    }

    /*
     * Single-step login drops the second factor. The password is still verified,
     * so this is weaker rather than open — but it is a deliberate reduction, and
     * a configuration file copied to production should not apply it quietly.
     */
    if (auth.LoginMode == LoginMode.SinglePassword && !builder.Environment.IsDevelopment())
    {
        throw new InvalidOperationException(
            $"Auth:LoginMode is SinglePassword in the '{builder.Environment.EnvironmentName}' " +
            "environment. That skips the one-time code and is only permitted in Development. " +
            "Set it to TwoStep before deploying.");
    }

    /*
     * Resolve the signing key once, here, and share it.
     *
     * Reading Jwt:SigningKey separately for signing and for validation is what
     * allowed the two to disagree, and a disagreement surfaces only as a 401
     * whose message points at the token rather than at the configuration.
     * SigningKeyProvider validates it and hands the same instance to both.
     */
    var signingKeyProvider = new SigningKeyProvider(
        Microsoft.Extensions.Options.Options.Create(jwt));

    Log.Information("JWT signing key fingerprint: {Fingerprint}", signingKeyProvider.Fingerprint);
    Log.Information("JWT issuer: {Issuer}  audience: {Audience}", jwt.Issuer, jwt.Audience);

    /*-------------------------------------------------------------- services */

    /* Dapper cannot pass DateOnly to SQL Server unaided — see the handlers.
       Registered before anything can run a query. */
    DapperConfiguration.Configure();

    builder.Services.AddHttpContextAccessor();

    /* Audit and timing are queued and drained in the background — see
       AuditWriter for why they are not written inline. */
    builder.Services.AddSingleton<IAuditWriter, AuditWriter>();
    builder.Services.AddHostedService<AuditDrainService>();
    builder.Services.AddSingleton<ISqlConnectionFactory, SqlConnectionFactory>();
    builder.Services.AddSingleton<IPasswordHasher, PasswordHasher>();
    builder.Services.AddSingleton(signingKeyProvider);
    builder.Services.AddSingleton<IJwtTokenService, JwtTokenService>();
    builder.Services.AddScoped<IOtpService, OtpService>();
    builder.Services.AddScoped<ICurrentUser, CurrentUser>();
    builder.Services.AddScoped<ILanguageContext, LanguageContext>();

    builder.Services.AddSingleton<IAuthorizationPolicyProvider, PermissionPolicyProvider>();
    builder.Services.AddSingleton<IAuthorizationHandler, PermissionHandler>();

    /*
     * Stop .NET rewriting the claim names.
     *
     * By default the JWT handler maps short claims to long WS-Federation URIs,
     * so "sub" silently becomes ClaimTypes.NameIdentifier and "unique_name"
     * becomes ClaimTypes.Name. Code reading the short name then finds nothing —
     * which showed up here as an empty cashier name on every sale rather than as
     * an error.
     */
    JwtSecurityTokenHandler.DefaultInboundClaimTypeMap.Clear();

    builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddJwtBearer(options =>
        {
            options.MapInboundClaims = false;
            options.TokenValidationParameters = new TokenValidationParameters
            {
                ValidateIssuer = true,
                ValidateAudience = true,
                ValidateLifetime = true,
                ValidateIssuerSigningKey = true,
                ValidIssuer = jwt.Issuer,
                ValidAudience = jwt.Audience,
                /* The same instance the token service signs with. Not a second
                   read of configuration — that is precisely what drifted. */
                IssuerSigningKey = signingKeyProvider.Key,
                // No leeway. The default five minutes means an expired token
                // keeps working for five more, which is five minutes too many.
                ClockSkew = TimeSpan.Zero
            };
        });

    builder.Services.AddAuthorization();

    /*
     * Rate limiting on the auth endpoints.
     *
     * A four-digit OTP has ten thousand possibilities. Without a limit at the
     * edge, per-challenge attempt counting is not enough — an attacker simply
     * requests fresh challenges. This caps the whole flow per caller.
     */
    builder.Services.AddRateLimiter(options =>
    {
        options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;

        options.AddPolicy("auth", context =>
            RateLimitPartition.GetFixedWindowLimiter(
                partitionKey: context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
                factory: _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = 10,
                    Window = TimeSpan.FromMinutes(1),
                    QueueLimit = 0
                }));

        options.AddPolicy("standard", context =>
            RateLimitPartition.GetFixedWindowLimiter(
                partitionKey: context.User.Identity?.Name
                              ?? context.Connection.RemoteIpAddress?.ToString()
                              ?? "unknown",
                factory: _ => new FixedWindowRateLimiterOptions
                {
                    PermitLimit = 300,
                    Window = TimeSpan.FromMinutes(1),
                    QueueLimit = 0
                }));
    });

    var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>()
                         ?? Array.Empty<string>();

    builder.Services.AddCors(options =>
        options.AddDefaultPolicy(policy =>
        {
            if (builder.Environment.IsDevelopment())
            {
                /* Any localhost port, and only in Development. Vite does not
                   always get the port it asks for, and a CORS rejection at that
                   moment is indistinguishable from the server being down. */
                policy.SetIsOriginAllowed(origin =>
                          Uri.TryCreate(origin, UriKind.Absolute, out var uri) &&
                          (uri.Host == "localhost" || uri.Host == "127.0.0.1"))
                      .AllowAnyHeader()
                      .AllowAnyMethod()
                      .AllowCredentials();
            }
            else
            {
                /* An explicit list in production. AllowAnyOrigin together with
                   credentials would let any site on the internet act as a
                   signed-in user. */
                policy.WithOrigins(allowedOrigins)
                      .AllowAnyHeader()
                      .AllowAnyMethod()
                      .AllowCredentials();
            }
        }));

    /*
     * Make Dapper's rows serialise like everything else.
     *
     * A Dapper row is an IDictionary<string, object>, and System.Text.Json
     * writes dictionary keys exactly as they are — so an endpoint returning a
     * typed record produced "invoiceNumber" while one returning a raw query
     * produced "InvoiceNumber". The client read the camelCase name, got
     * undefined, and rendered "Sale undefined completed".
     *
     * PropertyNamingPolicy alone does not fix it: that governs properties on
     * typed objects. DictionaryKeyPolicy is the one that applies to keys, and
     * without it the two halves of the API disagree about their own casing.
     */
    builder.Services.ConfigureHttpJsonOptions(options =>
    {
        options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
        options.SerializerOptions.DictionaryKeyPolicy = JsonNamingPolicy.CamelCase;
        options.SerializerOptions.DefaultIgnoreCondition =
            JsonIgnoreCondition.WhenWritingNull;
    });

    builder.Services.AddEndpointsApiExplorer();
    builder.Services.AddSwaggerGen(options =>
    {
        options.SwaggerDoc("v1", new OpenApiInfo
        {
            Title = "Nazad POS API",
            Version = "v1",
            Description =
                "Sign in first: POST /api/auth/login with " +
                "{\"identifier\": \"owner@demo.com\", \"password\": \"1234\"}, " +
                "then paste the accessToken into Authorize."
        });

        /*
         * Declare the bearer scheme.
         *
         * Without this Swagger has no idea the API uses tokens, so it renders no
         * Authorize button and every protected endpoint returns 401 with no way
         * to fix it from the page.
         */
        options.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
        {
            Name = "Authorization",
            Type = SecuritySchemeType.Http,
            Scheme = "bearer",
            BearerFormat = "JWT",
            In = ParameterLocation.Header,
            Description =
                "Paste only the token itself. Swagger adds the \"Bearer \" prefix, " +
                "so including it yourself produces \"Bearer Bearer ...\" and a 401."
        });

        /* Padlock only where a token is genuinely required — see the filter. */
        options.OperationFilter<AuthorizeCheckOperationFilter>();
    });

    var app = builder.Build();

    /*------------------------------------------------------------- pipeline */

    // One error shape for everything, and never the stack trace: an exception
    // message can name tables, paths and versions an attacker would rather not
    // have to guess.
    app.UseExceptionHandler(errorApp => errorApp.Run(async context =>
    {
        var feature = context.Features.Get<IExceptionHandlerFeature>();
        var logger = context.RequestServices.GetRequiredService<ILogger<Program>>();

        /*
         * A malformed request is the caller's mistake, not a fault.
         *
         * Model binding throws BadHttpRequestException for a missing or
         * unparseable parameter, and without this it lands here and is reported
         * as 500 — which says the server broke when it did not, and hides the
         * one detail that would fix it: which parameter.
         */
        if (feature?.Error is BadHttpRequestException badRequest)
        {
            logger.LogWarning("Bad request on {Path}: {Message}",
                context.Request.Path, badRequest.Message);

            context.Response.StatusCode = StatusCodes.Status400BadRequest;

            await context.Response.WriteAsJsonAsync(ApiError.Create(
                "bad_request",
                badRequest.Message,
                "الطلب غير صحيح. تحقّق من البيانات المُرسلة."));

            return;
        }

        /*
         * The full exception goes to the log, keyed by the correlation id; the
         * client gets the generic bilingual message and that id, nothing more.
         * The id is how a reported 500 is matched to this log line.
         */
        var correlationId = context.Items["CorrelationId"] as string
                            ?? Guid.NewGuid().ToString("N")[..16];

        logger.LogError(feature?.Error,
            "Unhandled exception on {Method} {Path} (correlation {CorrelationId})",
            context.Request.Method, context.Request.Path, correlationId);

        context.Response.StatusCode = StatusCodes.Status500InternalServerError;

        /*
         * Exception details in the response only when explicitly switched on.
         *
         * An exception message carries SQL text, table names, paths and
         * versions, and a stack trace maps the code — none of it belongs in a
         * response by default, not even in Development (a dev box exposed on a
         * LAN is still exposed). Errors:IncludeDetails turns it on for local
         * debugging, and Production ignores it even if set, so a config file
         * copied to the server cannot leak it.
         */
        var environment = context.RequestServices.GetRequiredService<IHostEnvironment>();
        var includeDetails = !environment.IsProduction() &&
                             context.RequestServices.GetRequiredService<IConfiguration>()
                                 .GetValue("Errors:IncludeDetails", false);

        if (includeDetails)
        {
            var error = feature?.Error;

            await context.Response.WriteAsJsonAsync(new
            {
                code = "server_error",
                messageEn = "Something went wrong. Please try again.",
                messageAr = "حدث خطأ ما. حاول مرة أخرى.",
                traceId = correlationId,
                correlationId,
                /* Errors:IncludeDetails only, never in Production. */
                developerMessage = error?.Message,
                exceptionType = error?.GetType().FullName,
                innerMessage = error?.InnerException?.Message,
                stackTrace = error?.StackTrace?.Split('\n').Take(8).ToArray()
            });

            return;
        }

        await context.Response.WriteAsJsonAsync(new
        {
            code = "server_error",
            messageEn = "Something went wrong. Please try again.",
            messageAr = "حدث خطأ ما. حاول مرة أخرى.",
            traceId = correlationId,
            correlationId
        });
    }));

    if (app.Environment.IsDevelopment())
    {
        app.UseSwagger();
        app.UseSwaggerUI(options =>
        {
            options.SwaggerEndpoint("/swagger/v1/swagger.json", "Nazad POS API v1");
            options.RoutePrefix = "swagger";
        });
    }

    /*
     * Never redirect in Development.
     *
     * Redirecting the plain-HTTP port to HTTPS sends the browser to a
     * certificate it has not been asked to trust. The request fails at the TLS
     * handshake, and what surfaces in the console is "Failed to fetch" — which
     * reads like a CORS problem and sends you looking in the wrong place.
     *
     * In production TLS is terminated by the reverse proxy, so it belongs there.
     */
    if (!app.Environment.IsDevelopment())
    {
        app.UseHttpsRedirection();
        app.UseHsts();
    }

    /* The built frontend, when present. Before CORS, the audit trail and
       authentication: loading the app's files needs none of them. */
    var frontendFiles = app.UseFrontendFiles();

    // CORS before authentication: a rejected preflight carries no credentials
    // and must not have to pass an authorization check.
    app.UseCors();
    /* Above authentication on purpose: a rejected request is still an event
       worth recording, and placing this below would miss every 401 and 403. */
    app.UseAuditTrail();
    app.UseSerilogRequestLogging();
    app.UseRateLimiter();
    app.UseAuthentication();
    app.UseAuthorization();

    app.MapAuthEndpoints();
    app.MapCatalogEndpoints();
    app.MapSalesEndpoints();
    app.MapReturnEndpoints();
    app.MapCustomerEndpoints();
    app.MapFinanceEndpoints();
    app.MapFinanceDetailEndpoints();
    app.MapReferenceEndpoints();
    app.MapCompanyEndpoints();
    app.MapInventoryEndpoints();
    app.MapVendorEndpoints();
    app.MapExpenseEndpoints();
    app.MapExpenseSetupEndpoints();
    app.MapKitchenEndpoints();
    app.MapDiscountEndpoints();
    app.MapUserEndpoints();
    app.MapStaffEndpoints();
    app.MapCashEndpoints();
    app.MapPayrollEndpoints();
    app.MapCommissionRuleEndpoints();
    app.MapNotificationEndpoints();
    app.MapActivationEndpoints();
    app.MapDeviceEndpoints();
    app.MapDiscoveryEndpoints();
    app.MapAuditEndpoints();
    app.MapSearchEndpoints();
    app.MapStocktakeEndpoints();

    app.MapGet("/health", () => Results.Ok(new
    {
        status = "ok",
        utc = DateTime.UtcNow,
        /* Which binary is answering. Compare against when you last built. */
        builtAtUtc,
        environment = app.Environment.EnvironmentName
    }))
       .AllowAnonymous()
       .WithTags("Health");

    app.MapGet("/health/db", async (ISqlConnectionFactory db, CancellationToken ct) =>
    {
        await using var connection = await db.CreateOpenAsync(ct);
        return Results.Ok(new { status = "ok", database = connection.Database });
    }).AllowAnonymous().WithTags("Health");

    /* Last: only what no API route claimed falls through to the app. */
    app.MapFrontendFallback(frontendFiles);

    /*
     * Print where it is actually listening.
     *
     * Kestrel logs this too, but only if a sink exists — and the addresses are
     * the one thing worth never having to guess, so they are stated here as well.
     */
    app.Lifetime.ApplicationStarted.Register(() =>
    {
        var addresses = app.Services
            .GetRequiredService<IServer>()
            .Features.Get<IServerAddressesFeature>()
            ?.Addresses;

        if (addresses is null || addresses.Count == 0)
        {
            Log.Warning("Started, but no listening address was reported.");
            return;
        }

        foreach (var address in addresses)
        {
            Log.Information("Listening on {Address}", address);
            Log.Information("  health   {Address}/health", address);
            Log.Information("  database {Address}/health/db", address);

            if (app.Environment.IsDevelopment())
            {
                Log.Information("  swagger  {Address}/swagger", address);
            }
        }

        Log.Information("Press Ctrl+C to stop.");
    });

    app.Run();

    return 0;
}
catch (Exception ex)
{
    /*
     * The reason this file has this shape.
     *
     * Anything thrown above — a bad connection string, a missing signing key, a
     * DI registration that cannot be built, a port already in use — lands here
     * and is printed. Without it the process exits with a status code and no
     * output, which looks exactly like "it built and then did nothing".
     */
    Log.Fatal(ex, "The API failed to start.");

    // Also written plainly to stderr, in case the logger itself is the problem.
    Console.Error.WriteLine();
    Console.Error.WriteLine("=== STARTUP FAILED ===");
    Console.Error.WriteLine(ex.ToString());
    Console.Error.WriteLine();

    return 1;
}
finally
{
    // Serilog buffers. Without this the last messages — usually the ones
    // explaining the crash — are lost as the process exits.
    Log.CloseAndFlush();
}

// Exposed so integration tests can drive the app through WebApplicationFactory.
public partial class Program;
