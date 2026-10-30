using Dapper;
using PosApi.Auth;
using PosApi.Data;
using PosApi.Localization;

namespace PosApi.Features.Settings;

/// <summary>One hit in the header search. <c>Subtitle</c> is the detail that matched or identifies it.</summary>
public sealed record SearchHit(string Id, string Title, string? Subtitle, string? Status);

/// <summary>
/// The header search, grouped. A group the caller has no permission for is
/// absent (null), not empty — the screen can tell "nothing found" from "not
/// yours to search".
/// </summary>
public sealed record SearchResults(
    string Query,
    IReadOnlyList<SearchHit>? Items,
    IReadOnlyList<SearchHit>? Customers,
    IReadOnlyList<SearchHit>? Vendors,
    IReadOnlyList<SearchHit>? Invoices);

public static class SearchEndpoints
{
    private const int MinLength = 2;
    private const int DefaultTake = 5;

    public static void MapSearchEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGroup("/api/search")
           .WithTags("Search")
           .RequireAuthorization()
           .RequireRateLimiting("standard")
           .MapGet("", SearchAsync);
    }

    /// <summary>
    /// GET /api/search?q=cola — items by name, SKU or barcode; customers by
    /// name or phone; vendors by name, phone or VAT number; invoices by number.
    ///
    /// Each group is searched only when the caller holds its view permission
    /// (products.view, customers.view, vendors.view, sales.view), and invoices
    /// only in the branches the caller can see — the same rules the list
    /// screens apply, so the search never shows what the screen it links to
    /// would refuse.
    /// </summary>
    private static async Task<IResult> SearchAsync(
        string? q, int? take, ISqlConnectionFactory db, ICurrentUser current,
        ILanguageContext language, CancellationToken ct)
    {
        var term = (q ?? string.Empty).Trim();

        if (term.Length < MinLength)
            return Results.Ok(new SearchResults(term, [], [], [], []));

        /* LIKE wildcards in what the user typed are literal characters
           (backslash is ILIKE's default escape). */
        var like = "%" + term.Replace(@"\", @"\\").Replace("%", @"\%").Replace("_", @"\_") + "%";
        var limit = Math.Clamp(take ?? DefaultTake, 1, 20);

        await using var connection = db.Create();

        IReadOnlyList<SearchHit>? items = null, customers = null, vendors = null, invoices = null;

        if (current.Can("products.view"))
        {
            var rows = await connection.QueryAsync<NamedRow>(new CommandDefinition(
                """
                SELECT ItemId AS Id, NameAr, NameEn,
                       COALESCE(Sku, Barcode) AS Detail,
                       CASE WHEN IsActive THEN 'active' ELSE 'inactive' END AS Status
                FROM core.CatalogItem
                WHERE NameAr COLLATE "default" ILIKE @Like OR NameEn COLLATE "default" ILIKE @Like
                   OR Sku COLLATE "default" ILIKE @Like OR Barcode = @Term
                ORDER BY CASE WHEN Sku = @Term OR Barcode = @Term THEN 0 ELSE 1 END,
                         IsActive DESC, NameEn
                LIMIT @Take;
                """,
                new { Take = limit, Like = like, Term = term }, cancellationToken: ct));
            items = rows.Select(r => r.ToHit(language)).ToList();
        }

        if (current.Can("customers.view"))
        {
            var rows = await connection.QueryAsync<NamedRow>(new CommandDefinition(
                """
                SELECT CustomerId AS Id, NameAr, NameEn, Phone AS Detail,
                       CASE WHEN IsActive THEN 'active' ELSE 'inactive' END AS Status
                FROM core.Customer
                WHERE NameAr COLLATE "default" ILIKE @Like OR NameEn COLLATE "default" ILIKE @Like
                   OR Phone COLLATE "default" ILIKE @Like
                ORDER BY IsActive DESC, NameEn
                LIMIT @Take;
                """,
                new { Take = limit, Like = like }, cancellationToken: ct));
            customers = rows.Select(r => r.ToHit(language)).ToList();
        }

        if (current.Can("vendors.view"))
        {
            var rows = await connection.QueryAsync<NamedRow>(new CommandDefinition(
                """
                SELECT VendorId AS Id, NameAr, NameEn,
                       COALESCE(Phone, VatNumber) AS Detail,
                       CASE WHEN IsActive THEN 'active' ELSE 'inactive' END AS Status
                FROM core.Vendor
                WHERE NameAr COLLATE "default" ILIKE @Like OR NameEn COLLATE "default" ILIKE @Like
                   OR Phone COLLATE "default" ILIKE @Like OR VatNumber COLLATE "default" ILIKE @Like
                ORDER BY IsActive DESC, NameEn
                LIMIT @Take;
                """,
                new { Take = limit, Like = like }, cancellationToken: ct));
            vendors = rows.Select(r => r.ToHit(language)).ToList();
        }

        if (current.Can("sales.view"))
        {
            var rows = await connection.QueryAsync<InvoiceRow>(new CommandDefinition(
                """
                SELECT s.SaleId, s.InvoiceNumber, s.TotalH, s.Status, s.SoldAtUtc,
                       c.NameAr AS CustomerNameAr, c.NameEn AS CustomerNameEn
                FROM sales.Sale AS s
                LEFT JOIN core.Customer AS c ON c.CustomerId = s.CustomerId
                WHERE s.InvoiceNumber COLLATE "default" ILIKE @Like
                  AND (@AllBranches OR s.BranchId IS NULL
                       OR s.BranchId = ANY(string_to_array(@Branches, ',')))
                ORDER BY CASE WHEN s.InvoiceNumber = @Term THEN 0 ELSE 1 END, s.SoldAtUtc DESC
                LIMIT @Take;
                """,
                new
                {
                    Take = limit, Like = like, Term = term,
                    AllBranches = current.BranchIds.Count == 0,
                    Branches = string.Join(',', current.BranchIds)
                },
                cancellationToken: ct));

            invoices = rows.Select(r => new SearchHit(
                r.SaleId,
                r.InvoiceNumber,
                string.Join(" · ", new[]
                {
                    $"SAR {r.TotalH / 100m:N2}",
                    r.SoldAtUtc.ToString("yyyy-MM-dd"),
                    r.CustomerNameEn is null ? null : language.Pick(r.CustomerNameAr ?? r.CustomerNameEn, r.CustomerNameEn)
                }.Where(part => !string.IsNullOrEmpty(part))),
                r.Status)).ToList();
        }

        return Results.Ok(new SearchResults(term, items, customers, vendors, invoices));
    }

    private sealed record NamedRow
    {
        public string Id { get; init; } = string.Empty;
        public string NameAr { get; init; } = string.Empty;
        public string NameEn { get; init; } = string.Empty;
        public string? Detail { get; init; }
        public string? Status { get; init; }

        public SearchHit ToHit(ILanguageContext language) =>
            new(Id, language.Pick(NameAr, NameEn), Detail, Status);
    }

    private sealed record InvoiceRow
    {
        public string SaleId { get; init; } = string.Empty;
        public string InvoiceNumber { get; init; } = string.Empty;
        public long TotalH { get; init; }
        public string? Status { get; init; }
        public DateTime SoldAtUtc { get; init; }
        public string? CustomerNameAr { get; init; }
        public string? CustomerNameEn { get; init; }
    }
}
