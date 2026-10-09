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
    private static readonly string[] ServerPrefixes = ["/api", "/health", "/swagger", AdminPath];

    /// <summary>Where the SaaS console (POSA, built into src/frontend-admin) is served.</summary>
    public const string AdminPath = "/admin";

    /// <summary>
    /// Where the build is: Frontend:Path if configured, else frontend/ next to
    /// the content root (a published app), else ../frontend (running from
    /// src/PosApi in the repository). Null when none holds an index.html.
    /// </summary>
    public static string? ResolveRoot(IConfiguration configuration, IWebHostEnvironment environment,
                                      string folder = "frontend", string setting = "Frontend:Path")
    {
        var configured = configuration[setting];
        var candidates = string.IsNullOrWhiteSpace(configured)
            ? new[]
            {
                Path.Combine(environment.ContentRootPath, folder),
                Path.Combine(environment.ContentRootPath, "..", folder),
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

    /*-------------------------------------------------------- the console */

    /// <summary>
    /// The SaaS console's build (build-frontend-admin writes src/frontend-admin),
    /// at /admin. Frontend:AdminPath overrides where it is read from.
    /// </summary>
    public static IFileProvider? UseAdminFrontendFiles(this WebApplication app)
    {
        var root = ResolveRoot(app.Configuration, app.Environment, "frontend-admin", "Frontend:AdminPath");

        if (root is null)
        {
            app.Logger.LogInformation(
                "No console build found (run build-frontend-admin). /admin is not served.");
            return null;
        }

        var files = new PhysicalFileProvider(root);

        /* The build uses relative asset paths, so /admin must end in a slash
           or the browser resolves ./assets against the site root. */
        app.Use(async (context, next) =>
        {
            if (context.Request.Path.Equals(AdminPath, StringComparison.OrdinalIgnoreCase))
            {
                context.Response.Redirect(AdminPath + "/" + context.Request.QueryString);
                return;
            }

            await next();
        });

        app.UseStaticFiles(new StaticFileOptions
        {
            FileProvider = files,
            RequestPath = AdminPath,
            OnPrepareResponse = context =>
            {
                context.Context.Response.Headers[HeaderNames.CacheControl] =
                    context.Context.Request.Path.StartsWithSegments(AdminPath + "/assets")
                        ? "public, max-age=31536000, immutable"
                        : "no-cache";
            }
        });

        app.Logger.LogInformation("Serving the console from {Root} at {Path}/", root, AdminPath);
        return files;
    }

    /// <summary>/admin/ and anything under it that is not a file opens the console.</summary>
    public static void MapAdminFrontendFallback(this WebApplication app, IFileProvider? files)
    {
        if (files is null) return;

        /* nonfile, as MapFallback() uses: a route that also matched
           /admin/assets/x.js would claim the request, and static files skip
           any request that already has an endpoint — every asset would 404. */
        app.MapFallback(AdminPath + "/{**path:nonfile}", async context =>
        {
            if (Path.HasExtension(context.Request.Path.Value) || !HttpMethods.IsGet(context.Request.Method))
            {
                context.Response.StatusCode = StatusCodes.Status404NotFound;
                return;
            }

            context.Response.Headers[HeaderNames.CacheControl] = "no-cache";
            context.Response.ContentType = "text/html; charset=utf-8";
            await context.Response.SendFileAsync(files.GetFileInfo("index.html"));
        }).AllowAnonymous().ExcludeFromDescription();
    }
}
