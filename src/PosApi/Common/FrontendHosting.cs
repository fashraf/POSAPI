using Microsoft.Extensions.FileProviders;
using Microsoft.Net.Http.Headers;

namespace PosApi.Common;

/// <summary>
/// Serves the built React app (POSFO) from the same process as the API.
///
/// One origin for both means no CORS, no reverse proxy needed to stitch them
/// together, and the frontend's relative /api calls (VITE_API_BASE_URL empty)
/// reach this server as they are. build-frontend.sh / .cmd puts the build in
/// src/frontend; publishing copies it next to the binary as frontend/.
///
/// When no build is present the API runs exactly as before — the frontend is
/// optional, so a backend-only deployment or `dotnet run` without a build
/// still works.
/// </summary>
public static class FrontendHosting
{
    /* Paths the app never owns. A miss under these is the API's 404, not the
       app's index page — returning HTML to a fetch for /api/... turns a clear
       "not found" into a JSON parse error in the browser. */
    private static readonly string[] ServerPrefixes = ["/api", "/health", "/swagger"];

    /// <summary>
    /// Where the build is: Frontend:Path if configured, else frontend/ next to
    /// the content root (a published app), else ../frontend (running from
    /// src/PosApi in the repository). Null when none holds an index.html.
    /// </summary>
    public static string? ResolveRoot(IConfiguration configuration, IWebHostEnvironment environment)
    {
        var configured = configuration["Frontend:Path"];
        var candidates = string.IsNullOrWhiteSpace(configured)
            ? new[]
            {
                Path.Combine(environment.ContentRootPath, "frontend"),
                Path.Combine(environment.ContentRootPath, "..", "frontend"),
            }
            : new[] { Path.GetFullPath(configured, environment.ContentRootPath) };

        return candidates
            .Select(Path.GetFullPath)
            .FirstOrDefault(path => File.Exists(Path.Combine(path, "index.html")));
    }

    /// <summary>
    /// Static files: hashed assets cached for a year, everything else
    /// revalidated, so a new build is picked up on the next load.
    ///
    /// Call before the audit trail and authentication: loading the app is not
    /// an auditable event and needs no token, and running every script and
    /// image through those would fill the audit table with noise.
    /// </summary>
    public static IFileProvider? UseFrontendFiles(this WebApplication app)
    {
        var root = ResolveRoot(app.Configuration, app.Environment);

        if (root is null)
        {
            app.Logger.LogInformation(
                "No frontend build found (run build-frontend). Serving the API only.");
            return null;
        }

        var files = new PhysicalFileProvider(root);

        app.UseStaticFiles(new StaticFileOptions
        {
            FileProvider = files,
            OnPrepareResponse = context =>
            {
                var headers = context.Context.Response.Headers;

                /* Vite names everything under assets/ by content hash, so a
                   changed file is a new URL and the old one can be cached
                   forever. Anything else (favicon, manifest) is revalidated. */
                headers[HeaderNames.CacheControl] =
                    context.Context.Request.Path.StartsWithSegments("/assets")
                        ? "public, max-age=31536000, immutable"
                        : "no-cache";
            }
        });

        app.Logger.LogInformation("Serving the frontend from {Root}", root);
        return files;
    }

    /// <summary>
    /// Client-side routes: any GET that no endpoint matched and that is not an
    /// API path or a file gets index.html, so a refresh on /sales or a shared
    /// link to /catalog opens the app instead of a 404.
    /// </summary>
    public static void MapFrontendFallback(this WebApplication app, IFileProvider? files)
    {
        if (files is null) return;

        app.MapFallback(async context =>
        {
            var path = context.Request.Path;

            var isServerPath = ServerPrefixes.Any(prefix =>
                path.StartsWithSegments(prefix, StringComparison.OrdinalIgnoreCase));

            /* A missing /assets/x.js or /logo.png is a missing file. Answering
               it with index.html would hand the browser HTML as a script. */
            var looksLikeFile = Path.HasExtension(path.Value);

            if (isServerPath || looksLikeFile || !HttpMethods.IsGet(context.Request.Method))
            {
                context.Response.StatusCode = StatusCodes.Status404NotFound;
                return;
            }

            var index = files.GetFileInfo("index.html");

            /* Never cached: it names the current hashed assets, and a stale copy
               would keep loading the previous build. */
            context.Response.Headers[HeaderNames.CacheControl] = "no-cache";
            context.Response.ContentType = "text/html; charset=utf-8";
            await context.Response.SendFileAsync(index);
        }).AllowAnonymous().ExcludeFromDescription();
    }
}
