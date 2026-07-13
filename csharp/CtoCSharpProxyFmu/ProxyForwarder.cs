using System.Net.Http.Headers;

namespace CtoCSharpProxyFmu;

public sealed class ProxyForwarder
{
    private static readonly HashSet<string> ExcludedRequestHeaders = new(StringComparer.OrdinalIgnoreCase)
    {
        "Host",
        "Connection",
        "Keep-Alive",
        "Proxy-Connection",
        "TE",
        "Transfer-Encoding",
        "Upgrade",
        "Content-Length",
        "Content-Type"
    };

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly RequestLogHub _logHub;

    public ProxyForwarder(IHttpClientFactory httpClientFactory, RequestLogHub logHub)
    {
        _httpClientFactory = httpClientFactory;
        _logHub = logHub;
    }

    public async Task ForwardAsync(
        HttpContext context,
        string targetBaseUrl,
        string targetPath,
        string routeLabel,
        CancellationToken cancellationToken,
        string? defaultContentType = null)
    {
        var client = _httpClientFactory.CreateClient("proxy");
        var method = new HttpMethod(context.Request.Method);
        var query = context.Request.QueryString.HasValue ? context.Request.QueryString.Value : string.Empty;
        var targetUrl = $"{targetBaseUrl.TrimEnd('/')}{targetPath}{query}";

        _logHub.Log($"Входящий запрос: {method} {context.Request.Path}{query} -> {targetUrl} ({routeLabel})");

        using var request = new HttpRequestMessage(method, targetUrl);

        if (method != HttpMethod.Get && method != HttpMethod.Head && method != HttpMethod.Delete)
        {
            context.Request.EnableBuffering();
            context.Request.Body.Position = 0;

            using var buffer = new MemoryStream();
            await context.Request.Body.CopyToAsync(buffer, cancellationToken);
            var bodyBytes = buffer.ToArray();

            if (bodyBytes.Length > 0)
            {
                var incomingType = string.IsNullOrWhiteSpace(context.Request.ContentType)
                    ? "(не указан)"
                    : context.Request.ContentType;
                _logHub.Log($"Тело запроса: {bodyBytes.Length} байт, Content-Type: {incomingType}");
            }

            if (bodyBytes.Length > 0 || method == HttpMethod.Post || method == HttpMethod.Put || method == HttpMethod.Patch)
            {
                var content = new ByteArrayContent(bodyBytes);
                var contentType = context.Request.ContentType;

                if (string.IsNullOrWhiteSpace(contentType))
                {
                    contentType = defaultContentType ?? "application/json; charset=utf-8";
                }
                else if (!contentType.Contains("charset", StringComparison.OrdinalIgnoreCase)
                         && contentType.StartsWith("application/json", StringComparison.OrdinalIgnoreCase))
                {
                    contentType = "application/json; charset=utf-8";
                }

                content.Headers.ContentType = MediaTypeHeaderValue.Parse(contentType);
                request.Content = content;
            }
        }

        foreach (var header in context.Request.Headers)
        {
            if (ExcludedRequestHeaders.Contains(header.Key))
            {
                continue;
            }

            request.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray());
        }

        if (request.Content is not null && !request.Headers.Contains("Accept"))
        {
            request.Headers.TryAddWithoutValidation("Accept", "application/json");
        }

        using var response = await client.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken);

        context.Response.StatusCode = (int)response.StatusCode;

        foreach (var header in response.Headers)
        {
            context.Response.Headers[header.Key] = header.Value.ToArray();
        }

        foreach (var header in response.Content.Headers)
        {
            context.Response.Headers[header.Key] = header.Value.ToArray();
        }

        context.Response.Headers.Remove("transfer-encoding");

        await response.Content.CopyToAsync(context.Response.Body, cancellationToken);

        _logHub.Log($"Ответ: {method} {context.Request.Path} -> HTTP {(int)response.StatusCode} ({routeLabel})");
    }
}
