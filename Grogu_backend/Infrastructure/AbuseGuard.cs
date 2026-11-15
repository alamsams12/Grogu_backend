using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Grogu.Infrastructure
{
    /// <summary>
    /// Protection for the endpoints anyone can post to without an account (bug
    /// reports and reviews on a public game page).
    ///
    /// <list type="bullet">
    /// <item><b>Client hash.</b> A salted SHA-256 of the caller's IP address. The
    ///   database rate-limits on it; the IP itself is never stored or logged.
    ///   The salt is <c>Abuse__Salt</c>, falling back to the JWT key, so the hash
    ///   can't be reversed by hashing every IPv4 address.</item>
    /// <item><b>Turnstile.</b> When <c>Turnstile__SecretKey</c> is set, anonymous
    ///   submissions must carry a valid Cloudflare Turnstile token
    ///   (<c>captchaToken</c>). Signed-in users skip it. Without the key, the IP
    ///   rate limits and the honeypot field still apply.</item>
    /// </list>
    ///
    /// Behind Render (and Cloudflare), the client address arrives in a header.
    /// <c>CF-Connecting-IP</c> / <c>True-Client-IP</c> are set by Cloudflare and
    /// preferred; then the first <c>X-Forwarded-For</c> entry; then the socket.
    /// A client can forge X-Forwarded-For when no proxy rewrites it, so this is a
    /// spam brake, not an identity check.
    /// </summary>
    public class AbuseGuard
    {
        private const string VerifyUrl = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

        private readonly ILogger<AbuseGuard> _logger;
        private readonly HttpClient _http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        private readonly byte[] _salt;
        private readonly string _turnstileSecret;

        public AbuseGuard(IConfiguration configuration, ILogger<AbuseGuard> logger)
        {
            _logger = logger;
            var salt = configuration["Abuse:Salt"];
            if (string.IsNullOrWhiteSpace(salt))
            {
                salt = configuration["Jwt:Key"] ?? "grogu";
            }
            _salt = Encoding.UTF8.GetBytes(salt);
            _turnstileSecret = (configuration["Turnstile:SecretKey"] ?? string.Empty).Trim();
        }

        public bool CaptchaRequired
        {
            get { return _turnstileSecret.Length > 0; }
        }

        public string ClientHash(HttpContext context)
        {
            var ip = ClientIp(context);
            if (string.IsNullOrEmpty(ip))
            {
                return null;
            }

            using (var hmac = new HMACSHA256(_salt))
            {
                var hash = hmac.ComputeHash(Encoding.UTF8.GetBytes(ip));
                var sb = new StringBuilder(hash.Length * 2);
                foreach (var b in hash)
                {
                    sb.Append(b.ToString("x2"));
                }
                return sb.ToString();
            }
        }

        public static string ClientIp(HttpContext context)
        {
            var headers = context.Request.Headers;
            foreach (var name in new[] { "CF-Connecting-IP", "True-Client-IP" })
            {
                var value = headers[name].ToString().Trim();
                if (value.Length > 0 && value.Length <= 64)
                {
                    return value;
                }
            }

            var forwarded = headers["X-Forwarded-For"].ToString();
            if (!string.IsNullOrWhiteSpace(forwarded))
            {
                var first = forwarded.Split(',')[0].Trim();
                if (first.Length > 0 && first.Length <= 64)
                {
                    return first;
                }
            }

            return context.Connection.RemoteIpAddress == null ? null : context.Connection.RemoteIpAddress.ToString();
        }

        /// <summary>True when Turnstile is off, or the token checks out with Cloudflare.</summary>
        public async Task<bool> VerifyCaptchaAsync(string token, string remoteIp)
        {
            if (!CaptchaRequired)
            {
                return true;
            }
            if (string.IsNullOrWhiteSpace(token) || token.Length > 2048)
            {
                return false;
            }

            var form = new Dictionary<string, string> { { "secret", _turnstileSecret }, { "response", token } };
            if (!string.IsNullOrEmpty(remoteIp))
            {
                form["remoteip"] = remoteIp;
            }

            try
            {
                using (var response = await _http.PostAsync(VerifyUrl, new FormUrlEncodedContent(form)))
                {
                    var body = await response.Content.ReadAsStringAsync();
                    using (var doc = JsonDocument.Parse(body))
                    {
                        JsonElement success;
                        return doc.RootElement.TryGetProperty("success", out success)
                               && success.ValueKind == JsonValueKind.True;
                    }
                }
            }
            catch (Exception ex) when (ex is HttpRequestException || ex is TaskCanceledException || ex is JsonException)
            {
                // Fail closed: if Cloudflare can't be asked, the visitor can sign in instead.
                _logger.LogWarning("Turnstile verification unavailable: {Type}", ex.GetType().Name);
                return false;
            }
        }
    }
}
