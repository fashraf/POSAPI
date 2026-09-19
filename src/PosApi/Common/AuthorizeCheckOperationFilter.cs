using Microsoft.AspNetCore.Authorization;
using Microsoft.OpenApi.Models;
using Swashbuckle.AspNetCore.SwaggerGen;

namespace PosApi.Common;

/// <summary>
/// Show the padlock only on endpoints that actually require a token.
///
/// A blanket security requirement puts a padlock on everything, including
/// /api/auth/login — which is open by design and has to be, since it is how you
/// obtain a token in the first place. Someone reading the page would conclude
/// they need to sign in before they can sign in.
///
/// This inspects what each endpoint really demands, so the documentation and
/// the behaviour agree.
/// </summary>
public sealed class AuthorizeCheckOperationFilter : IOperationFilter
{
    public void Apply(OpenApiOperation operation, OperationFilterContext context)
    {
        var metadata = context.ApiDescription.ActionDescriptor.EndpointMetadata;

        var allowsAnonymous = metadata.OfType<IAllowAnonymous>().Any();
        var requiresAuth = metadata.OfType<IAuthorizeData>().Any();

        if (allowsAnonymous || !requiresAuth) return;

        operation.Security =
        [
            new OpenApiSecurityRequirement
            {
                {
                    new OpenApiSecurityScheme
                    {
                        Reference = new OpenApiReference
                        {
                            Type = ReferenceType.SecurityScheme,
                            Id = "Bearer"
                        }
                    },
                    Array.Empty<string>()
                }
            }
        ];

        // Say what a 401 means here, rather than leaving the reader to guess
        // whether the token is missing, expired, or simply wrong.
        operation.Responses.TryAdd("401", new OpenApiResponse
        {
            Description = "No token, or the token has expired. Sign in again."
        });

        operation.Responses.TryAdd("403", new OpenApiResponse
        {
            Description = "Signed in, but this account lacks the required permission."
        });
    }
}
