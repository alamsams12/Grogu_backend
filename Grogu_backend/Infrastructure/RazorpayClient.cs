using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Grogu.Infrastructure
{
    public sealed class RazorpayOrderResult
    {
        public bool Ok { get; private set; }
        public string OrderId { get; private set; }
        /// <summary>Why the order was not created. Safe to store; never shown verbatim to users.</summary>
        public string Error { get; private set; }

        public static RazorpayOrderResult Success(string orderId)
        {
            return new RazorpayOrderResult { Ok = true, OrderId = orderId };
        }

        public static RazorpayOrderResult Fail(string error)
        {
            return new RazorpayOrderResult { Error = error };
        }
    }

    /// <summary>
    /// The parts of Razorpay the reward pool needs: creating an order and
    /// verifying the two kinds of signature Razorpay sends back.
    ///
    /// Configuration (environment variables use a double underscore):
    /// <list type="bullet">
    /// <item><c>Razorpay__KeyId</c> — public key id (<c>rzp_test_…</c> or <c>rzp_live_…</c>).
    ///   Sent to the browser so Checkout can open.</item>
    /// <item><c>Razorpay__KeySecret</c> — server-side only. Signs API calls and checkout callbacks.</item>
    /// <item><c>Razorpay__WebhookSecret</c> — the secret entered for the webhook in the Razorpay
    ///   dashboard. Optional, but without it payments are only recorded when the browser
    ///   returns from Checkout.</item>
    /// <item><c>Razorpay__BaseUrl</c> — default <c>https://api.razorpay.com</c>.</item>
    /// </list>
    ///
    /// Without a key id and secret the client is inert and the payment endpoints
    /// answer that payments aren't set up. Secrets and signatures are never logged.
    /// </summary>
    public class RazorpayClient
    {
        private const string DefaultBaseUrl = "https://api.razorpay.com";

        private readonly ILogger<RazorpayClient> _logger;
        private readonly HttpClient _http;
        private readonly string _keyId;
        private readonly string _keySecret;
        private readonly string _webhookSecret;
        private readonly string _baseUrl;

        public RazorpayClient(IConfiguration configuration, ILogger<RazorpayClient> logger)
        {
            _logger = logger;
            _keyId = (configuration["Razorpay:KeyId"] ?? string.Empty).Trim();
            _keySecret = (configuration["Razorpay:KeySecret"] ?? string.Empty).Trim();
            _webhookSecret = (configuration["Razorpay:WebhookSecret"] ?? string.Empty).Trim();

            var baseUrl = (configuration["Razorpay:BaseUrl"] ?? string.Empty).Trim();
            _baseUrl = (baseUrl.Length == 0 ? DefaultBaseUrl : baseUrl).TrimEnd('/');

            _http = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };

            if (_keyId.Length > 0 && _keySecret.Length == 0)
            {
                _logger.LogWarning("Razorpay:KeyId is set without Razorpay:KeySecret; payments are disabled.");
            }
        }

        public bool IsConfigured
        {
            get { return _keyId.Length > 0 && _keySecret.Length > 0; }
        }

        public bool WebhookConfigured
        {
            get { return _webhookSecret.Length > 0; }
        }

        public string KeyId
        {
            get { return _keyId; }
        }

        /// <summary>Test keys start with rzp_test_; the UI says so, so nobody pays real money by mistake.</summary>
        public bool TestMode
        {
            get { return _keyId.StartsWith("rzp_test_", StringComparison.Ordinal); }
        }

        /// <summary>
        /// Creates an order (POST /v1/orders). Never throws: a network error,
        /// timeout or refusal comes back as a failed result.
        /// </summary>
        public async Task<RazorpayOrderResult> CreateOrderAsync(
            long amountPaise, string currency, string receipt, string playtestId, string userId)
        {
            if (!IsConfigured)
            {
                return RazorpayOrderResult.Fail("not-configured");
            }

            var payload = JsonSerializer.Serialize(new
            {
                amount = amountPaise,
                currency = currency,
                receipt = receipt,
                notes = new { playtest_id = playtestId, user_id = userId, purpose = "grogu-reward-pool" }
            });

            try
            {
                using (var request = new HttpRequestMessage(HttpMethod.Post, _baseUrl + "/v1/orders"))
                {
                    request.Headers.Authorization = new AuthenticationHeaderValue(
                        "Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes(_keyId + ":" + _keySecret)));
                    request.Content = new StringContent(payload, Encoding.UTF8, "application/json");

                    using (var response = await _http.SendAsync(request))
                    {
                        var body = await response.Content.ReadAsStringAsync();

                        if (!response.IsSuccessStatusCode)
                        {
                            // Razorpay's error description names the problem (bad key, bad
                            // amount) and contains no secret, so it is safe to log.
                            var description = ErrorDescription(body);
                            _logger.LogWarning("Razorpay order creation failed: HTTP {Status} {Description}",
                                (int)response.StatusCode, description);
                            return RazorpayOrderResult.Fail("HTTP " + (int)response.StatusCode + ": " + description);
                        }

                        using (var doc = JsonDocument.Parse(body))
                        {
                            JsonElement id;
                            if (doc.RootElement.TryGetProperty("id", out id) && id.ValueKind == JsonValueKind.String)
                            {
                                return RazorpayOrderResult.Success(id.GetString());
                            }
                        }

                        return RazorpayOrderResult.Fail("Razorpay returned no order id.");
                    }
                }
            }
            catch (TaskCanceledException)
            {
                _logger.LogWarning("Razorpay order creation timed out.");
                return RazorpayOrderResult.Fail("timeout");
            }
            catch (HttpRequestException ex)
            {
                _logger.LogWarning("Razorpay unreachable: {Message}", ex.Message);
                return RazorpayOrderResult.Fail("unreachable");
            }
            catch (JsonException)
            {
                return RazorpayOrderResult.Fail("Razorpay returned an unreadable response.");
            }
        }

        /// <summary>
        /// Checkout's success callback: signature = HMAC-SHA256(order_id + "|" + payment_id, key_secret).
        /// </summary>
        public bool VerifyPaymentSignature(string orderId, string paymentId, string signature)
        {
            if (!IsConfigured || string.IsNullOrEmpty(orderId) || string.IsNullOrEmpty(paymentId)
                || string.IsNullOrEmpty(signature))
            {
                return false;
            }

            return SignatureMatches(orderId + "|" + paymentId, _keySecret, signature);
        }

        /// <summary>Webhook: X-Razorpay-Signature = HMAC-SHA256(raw body, webhook_secret).</summary>
        public bool VerifyWebhookSignature(string rawBody, string signature)
        {
            if (!WebhookConfigured || rawBody == null || string.IsNullOrEmpty(signature))
            {
                return false;
            }

            return SignatureMatches(rawBody, _webhookSecret, signature);
        }

        private static bool SignatureMatches(string message, string secret, string signatureHex)
        {
            byte[] expected;
            using (var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(secret)))
            {
                expected = hmac.ComputeHash(Encoding.UTF8.GetBytes(message));
            }

            byte[] given;
            try
            {
                given = HexToBytes(signatureHex.Trim());
            }
            catch (FormatException)
            {
                return false;
            }

            // Constant-time, so the comparison leaks nothing about how much matched.
            return given.Length == expected.Length && CryptographicOperations.FixedTimeEquals(given, expected);
        }

        private static byte[] HexToBytes(string hex)
        {
            if (hex.Length % 2 != 0)
            {
                throw new FormatException();
            }

            var bytes = new byte[hex.Length / 2];
            for (var i = 0; i < bytes.Length; i++)
            {
                bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            }
            return bytes;
        }

        private static string ErrorDescription(string body)
        {
            try
            {
                using (var doc = JsonDocument.Parse(body))
                {
                    JsonElement error, description;
                    if (doc.RootElement.TryGetProperty("error", out error)
                        && error.TryGetProperty("description", out description)
                        && description.ValueKind == JsonValueKind.String)
                    {
                        var text = description.GetString();
                        return text.Length > 200 ? text.Substring(0, 200) : text;
                    }
                }
            }
            catch (JsonException)
            {
            }

            return "unknown error";
        }
    }
}
