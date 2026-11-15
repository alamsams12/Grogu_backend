using System;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Grogu.Infrastructure
{
    /// <summary>
    /// Sends the few transactional emails the API needs (password reset links).
    ///
    /// Configuration (environment variables use a double underscore):
    /// <list type="bullet">
    /// <item><c>Email__ResendApiKey</c> — a Resend API key. Server-side only.</item>
    /// <item><c>Email__From</c> — the sender, e.g. <c>Grogu &lt;no-reply@yourdomain.com&gt;</c>, on a
    ///   domain verified in Resend. Resend's <c>onboarding@resend.dev</c> works for testing but
    ///   only delivers to your own Resend account's address.</item>
    /// <item><c>App__FrontendUrl</c> — the site links point to, e.g.
    ///   <c>https://project-grogu-pi.vercel.app</c>. Never taken from the request, so a forged
    ///   Host or Origin header can't redirect someone's reset link.</item>
    /// </list>
    ///
    /// Without a key, nothing is sent. In Development the message (including the
    /// link) is written to the log instead so the flow can be tested locally; in
    /// any other environment the link is never logged.
    /// </summary>
    public class EmailSender
    {
        private readonly ILogger<EmailSender> _logger;
        private readonly HttpClient _http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        private readonly string _apiKey;
        private readonly string _from;
        private readonly bool _development;

        public EmailSender(IConfiguration configuration, IWebHostEnvironment environment, ILogger<EmailSender> logger)
        {
            _logger = logger;
            _apiKey = (configuration["Email:ResendApiKey"] ?? string.Empty).Trim();
            _from = (configuration["Email:From"] ?? string.Empty).Trim();
            if (_from.Length == 0)
            {
                _from = "Grogu <onboarding@resend.dev>";
            }
            _development = environment.IsDevelopment();

            var frontend = (configuration["App:FrontendUrl"] ?? string.Empty).Trim().TrimEnd('/');
            Uri uri;
            FrontendUrl = Uri.TryCreate(frontend, UriKind.Absolute, out uri)
                          && (uri.Scheme == Uri.UriSchemeHttps || uri.Scheme == Uri.UriSchemeHttp)
                ? frontend
                : "http://localhost:3000";
        }

        public bool IsConfigured
        {
            get { return _apiKey.Length > 0; }
        }

        /// <summary>The frontend's origin, for links in emails.</summary>
        public string FrontendUrl { get; private set; }

        /// <summary>Never throws; returns whether the provider accepted the message.</summary>
        public async Task<bool> SendAsync(string to, string subject, string text, string html)
        {
            if (!IsConfigured)
            {
                if (_development)
                {
                    _logger.LogWarning("Email not configured (Email__ResendApiKey). Development copy for {To}: {Subject}\n{Text}",
                        to, subject, text);
                }
                else
                {
                    _logger.LogWarning("Email not configured (Email__ResendApiKey); a \"{Subject}\" email was not sent.", subject);
                }
                return false;
            }

            var payload = JsonSerializer.Serialize(new { from = _from, to = new[] { to }, subject, text, html });

            try
            {
                using (var request = new HttpRequestMessage(HttpMethod.Post, "https://api.resend.com/emails"))
                {
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
                    request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

                    using (var response = await _http.SendAsync(request))
                    {
                        if (response.IsSuccessStatusCode)
                        {
                            return true;
                        }
                        // The body names the problem (unverified domain, bad key) and holds no secret.
                        var body = await response.Content.ReadAsStringAsync();
                        _logger.LogWarning("Resend refused an email: HTTP {Status} {Body}", (int)response.StatusCode,
                            body.Length > 300 ? body.Substring(0, 300) : body);
                        return false;
                    }
                }
            }
            catch (Exception ex) when (ex is HttpRequestException || ex is TaskCanceledException)
            {
                _logger.LogWarning("Resend unreachable: {Type}", ex.GetType().Name);
                return false;
            }
        }

        public Task<bool> SendPasswordResetAsync(string to, string name, string link)
        {
            var greeting = string.IsNullOrWhiteSpace(name) ? "Hi" : "Hi " + name;
            var text =
                greeting + ",\n\n" +
                "Someone (hopefully you) asked to reset your Grogu password. Open this link within 30 minutes to choose a new one:\n\n" +
                link + "\n\n" +
                "If you didn't ask for this, ignore this email; your password stays the same.\n\n— Grogu";

            var safeName = WebUtility.HtmlEncode(greeting);
            var safeLink = WebUtility.HtmlEncode(link);
            var html =
                "<div style=\"font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;max-width:480px;margin:auto;color:#17142b\">" +
                "<h1 style=\"font-size:22px\">Reset your password</h1>" +
                "<p>" + safeName + ",</p>" +
                "<p>Someone (hopefully you) asked to reset your Grogu password. The link works once, for 30 minutes.</p>" +
                "<p><a href=\"" + safeLink + "\" style=\"display:inline-block;background:#5b3ff0;color:#fff;padding:12px 20px;" +
                "border:3px solid #17142b;border-radius:10px;font-weight:700;text-decoration:none\">Choose a new password</a></p>" +
                "<p style=\"font-size:13px;color:#555\">Or paste this into your browser:<br>" + safeLink + "</p>" +
                "<p style=\"font-size:13px;color:#555\">If you didn't ask for this, ignore this email; your password stays the same.</p>" +
                "</div>";

            return SendAsync(to, "Reset your Grogu password", text, html);
        }
    }
}
