using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Grogu.Infrastructure
{
    /// <summary>Why a Gemini call produced no usable answer.</summary>
    public enum GeminiFailure
    {
        None,
        NotConfigured,
        /// <summary>Calls per minute are used up (ours), or Gemini answered 429.</summary>
        RateLimited,
        /// <summary>This playtest's last attempt was recent, so it is not retried yet.</summary>
        CoolingDown,
        /// <summary>Too many calls already in flight.</summary>
        Busy,
        Timeout,
        /// <summary>Network error, 5xx, or a request Gemini rejected (bad key or model).</summary>
        Unavailable,
        /// <summary>The model declined to answer (safety or similar).</summary>
        Blocked,
        /// <summary>The call succeeded but the answer was not usable JSON.</summary>
        BadResponse
    }

    public sealed class GeminiResult
    {
        public GeminiFailure Failure { get; private set; }
        public bool Ok { get { return Failure == GeminiFailure.None; } }

        /// <summary>The model's answer, as JSON text, when <see cref="Ok"/>.</summary>
        public string Json { get; private set; }

        public string Model { get; private set; }

        public static GeminiResult Success(string json, string model)
        {
            return new GeminiResult { Json = json, Model = model };
        }

        public static GeminiResult Fail(GeminiFailure failure)
        {
            return new GeminiResult { Failure = failure };
        }
    }

    /// <summary>
    /// A thin client for Gemini's <c>generateContent</c> endpoint that always
    /// returns a result and never throws, so a caller can fall back instead of
    /// breaking the page.
    ///
    /// Configuration (environment variables use a double underscore):
    /// <list type="bullet">
    /// <item><c>Gemini__ApiKey</c> — the key. Server-side only. Without it every call returns
    ///   <see cref="GeminiFailure.NotConfigured"/> and nothing is sent anywhere.</item>
    /// <item><c>Gemini__Model</c> — model id; default <c>gemini-3.1-flash-lite</c>.</item>
    /// <item><c>Gemini__BaseUrl</c> — default <c>https://generativelanguage.googleapis.com</c>.</item>
    /// <item><c>Gemini__TimeoutSeconds</c> (30), <c>Gemini__CooldownSeconds</c> (60 per rate key),
    ///   <c>Gemini__MaxCallsPerMinute</c> (10).</item>
    /// </list>
    ///
    /// The key is sent in the <c>x-goog-api-key</c> header, never in the URL, and the
    /// prompt and answer are never logged.
    ///
    /// The limits exist for the free tier. A single instance is shared, so they
    /// hold per process; with more than one API instance each has its own.
    /// </summary>
    public class GeminiClient
    {
        // gemini-2.5-flash is no longer offered to new keys (HTTP 404), so the
        // default is the current flash model. Override with Gemini__Model.
        private const string DefaultModel = "gemini-3.1-flash-lite";
        private const string DefaultBaseUrl = "https://generativelanguage.googleapis.com";
        private const int MaxConcurrentCalls = 2;

        private readonly ILogger<GeminiClient> _logger;
        private readonly HttpClient _http;
        private readonly string _apiKey;
        private readonly string _baseUrl;
        private readonly string _model;
        private readonly TimeSpan _cooldown;
        private readonly int _maxPerMinute;
        private readonly SemaphoreSlim _slots = new SemaphoreSlim(MaxConcurrentCalls, MaxConcurrentCalls);

        private readonly object _gate = new object();
        private readonly Queue<DateTime> _recentCalls = new Queue<DateTime>();
        private readonly Dictionary<string, DateTime> _lastAttempt = new Dictionary<string, DateTime>();

        public GeminiClient(IConfiguration configuration, ILogger<GeminiClient> logger)
        {
            _logger = logger;

            _apiKey = (configuration["Gemini:ApiKey"] ?? string.Empty).Trim();
            _model = Setting(configuration["Gemini:Model"], DefaultModel);
            _baseUrl = Setting(configuration["Gemini:BaseUrl"], DefaultBaseUrl).TrimEnd('/');
            _cooldown = TimeSpan.FromSeconds(Seconds(configuration["Gemini:CooldownSeconds"], 60, 0, 3600));
            _maxPerMinute = Seconds(configuration["Gemini:MaxCallsPerMinute"], 10, 1, 600);

            _http = new HttpClient
            {
                Timeout = TimeSpan.FromSeconds(Seconds(configuration["Gemini:TimeoutSeconds"], 30, 5, 120))
            };

            Uri baseUri;
            if (_apiKey.Length > 0 &&
                !(Uri.TryCreate(_baseUrl, UriKind.Absolute, out baseUri) &&
                  (baseUri.Scheme == Uri.UriSchemeHttps || baseUri.Scheme == Uri.UriSchemeHttp)))
            {
                _logger.LogWarning("Gemini:BaseUrl is not a valid http(s) URL; Gemini is disabled.");
                _apiKey = string.Empty;
            }

            _logger.LogInformation(
                _apiKey.Length > 0
                    ? "Gemini is enabled (model {Model})."
                    : "Gemini is not configured; summaries use the rule-based fallback.",
                _model);
        }

        public bool IsConfigured { get { return _apiKey.Length > 0; } }

        public string Model { get { return _model; } }

        /// <summary>
        /// Asks the model for a JSON answer matching <paramref name="responseSchema"/>.
        /// <paramref name="rateKey"/> identifies what is being generated (for example
        /// one playtest) so the same thing is not regenerated within the cooldown.
        /// </summary>
        public async Task<GeminiResult> GenerateJsonAsync(
            string rateKey, string systemInstruction, string userContent, object responseSchema)
        {
            if (!IsConfigured)
            {
                return GeminiResult.Fail(GeminiFailure.NotConfigured);
            }

            // Busy is checked first so a rejected call does not use up quota.
            if (!await _slots.WaitAsync(0))
            {
                return GeminiResult.Fail(GeminiFailure.Busy);
            }

            try
            {
                var refused = Reserve(rateKey);
                if (refused != GeminiFailure.None)
                {
                    return GeminiResult.Fail(refused);
                }

                try
                {
                    return await SendAsync(systemInstruction, userContent, responseSchema);
                }
                finally
                {
                    // The cooldown runs from the end of the attempt, so a call that
                    // timed out after 30 seconds still gets its full cool-off.
                    MarkAttempt(rateKey);
                }
            }
            finally
            {
                _slots.Release();
            }
        }

        private async Task<GeminiResult> SendAsync(string systemInstruction, string userContent, object responseSchema)
        {
            var body = JsonSerializer.Serialize(new
            {
                systemInstruction = new { parts = new[] { new { text = systemInstruction } } },
                contents = new[] { new { role = "user", parts = new[] { new { text = userContent } } } },
                generationConfig = new
                {
                    responseMimeType = "application/json",
                    responseSchema,
                    temperature = 0.2,
                    maxOutputTokens = 2048
                }
            });

            var url = _baseUrl + "/v1beta/models/" + Uri.EscapeDataString(_model) + ":generateContent";

            try
            {
                using (var request = new HttpRequestMessage(HttpMethod.Post, url))
                {
                    request.Content = new StringContent(body, Encoding.UTF8, "application/json");
                    request.Headers.Add("x-goog-api-key", _apiKey);

                    using (var response = await _http.SendAsync(request))
                    {
                        if (response.StatusCode == (HttpStatusCode)429)
                        {
                            _logger.LogWarning("Gemini rate-limited the request (HTTP 429).");
                            return GeminiResult.Fail(GeminiFailure.RateLimited);
                        }

                        if (!response.IsSuccessStatusCode)
                        {
                            // 4xx other than 429 means our request or key is wrong, which an
                            // operator needs to see; 5xx is Gemini's own trouble.
                            var code = (int)response.StatusCode;
                            if (code >= 400 && code < 500)
                            {
                                _logger.LogError(
                                    "Gemini rejected the request (HTTP {Status}). Check Gemini:ApiKey and Gemini:Model.", code);
                            }
                            else
                            {
                                _logger.LogWarning("Gemini is unavailable (HTTP {Status}).", code);
                            }
                            return GeminiResult.Fail(GeminiFailure.Unavailable);
                        }

                        var text = await response.Content.ReadAsStringAsync();
                        return Parse(text);
                    }
                }
            }
            catch (TaskCanceledException)
            {
                _logger.LogWarning("Gemini did not answer in time.");
                return GeminiResult.Fail(GeminiFailure.Timeout);
            }
            catch (HttpRequestException ex)
            {
                _logger.LogWarning("Gemini could not be reached ({Error}).", ex.GetType().Name);
                return GeminiResult.Fail(GeminiFailure.Unavailable);
            }
        }

        /// <summary>Pulls the JSON answer out of a generateContent response.</summary>
        private GeminiResult Parse(string responseBody)
        {
            try
            {
                using (var doc = JsonDocument.Parse(responseBody))
                {
                    var root = doc.RootElement;

                    JsonElement feedback;
                    if (root.TryGetProperty("promptFeedback", out feedback) &&
                        feedback.ValueKind == JsonValueKind.Object &&
                        feedback.TryGetProperty("blockReason", out _))
                    {
                        _logger.LogWarning("Gemini blocked the prompt.");
                        return GeminiResult.Fail(GeminiFailure.Blocked);
                    }

                    JsonElement candidates;
                    if (!root.TryGetProperty("candidates", out candidates) ||
                        candidates.ValueKind != JsonValueKind.Array ||
                        candidates.GetArrayLength() == 0)
                    {
                        return GeminiResult.Fail(GeminiFailure.BadResponse);
                    }

                    var candidate = candidates[0];

                    JsonElement finish;
                    if (candidate.TryGetProperty("finishReason", out finish) &&
                        finish.ValueKind == JsonValueKind.String)
                    {
                        var reason = finish.GetString();
                        if (reason != "STOP")
                        {
                            _logger.LogWarning("Gemini stopped early ({Reason}).", reason);
                            return GeminiResult.Fail(reason == "MAX_TOKENS" || reason == "OTHER"
                                ? GeminiFailure.BadResponse
                                : GeminiFailure.Blocked);
                        }
                    }

                    JsonElement content, parts;
                    if (!candidate.TryGetProperty("content", out content) ||
                        !content.TryGetProperty("parts", out parts) ||
                        parts.ValueKind != JsonValueKind.Array)
                    {
                        return GeminiResult.Fail(GeminiFailure.BadResponse);
                    }

                    // Thinking models may send reasoning as parts flagged "thought".
                    var answer = new StringBuilder();
                    foreach (var part in parts.EnumerateArray())
                    {
                        JsonElement thought, text;
                        if (part.TryGetProperty("thought", out thought) && thought.ValueKind == JsonValueKind.True)
                        {
                            continue;
                        }
                        if (part.TryGetProperty("text", out text) && text.ValueKind == JsonValueKind.String)
                        {
                            answer.Append(text.GetString());
                        }
                    }

                    var json = answer.ToString().Trim();
                    if (json.Length == 0)
                    {
                        return GeminiResult.Fail(GeminiFailure.BadResponse);
                    }

                    // The caller parses it for real; this only rejects text that is not JSON.
                    using (JsonDocument.Parse(json))
                    {
                        return GeminiResult.Success(json, _model);
                    }
                }
            }
            catch (JsonException)
            {
                return GeminiResult.Fail(GeminiFailure.BadResponse);
            }
        }

        /// <summary>
        /// Claims one call against the per-key cooldown and the per-minute budget.
        /// A claim is spent even if the call then fails, which is what stops a
        /// failing key from being retried in a tight loop.
        /// </summary>
        private GeminiFailure Reserve(string rateKey)
        {
            lock (_gate)
            {
                var now = DateTime.UtcNow;

                DateTime last;
                if (_cooldown > TimeSpan.Zero &&
                    _lastAttempt.TryGetValue(rateKey, out last) &&
                    now - last < _cooldown)
                {
                    return GeminiFailure.CoolingDown;
                }

                while (_recentCalls.Count > 0 && now - _recentCalls.Peek() >= TimeSpan.FromMinutes(1))
                {
                    _recentCalls.Dequeue();
                }
                if (_recentCalls.Count >= _maxPerMinute)
                {
                    return GeminiFailure.RateLimited;
                }

                _recentCalls.Enqueue(now);
                _lastAttempt[rateKey] = now;

                // Keep the map from growing without bound.
                if (_lastAttempt.Count > 2000)
                {
                    var stale = new List<string>();
                    foreach (var pair in _lastAttempt)
                    {
                        if (now - pair.Value > _cooldown) stale.Add(pair.Key);
                    }
                    foreach (var key in stale) _lastAttempt.Remove(key);
                }

                return GeminiFailure.None;
            }
        }

        private void MarkAttempt(string rateKey)
        {
            lock (_gate)
            {
                _lastAttempt[rateKey] = DateTime.UtcNow;
            }
        }

        private static string Setting(string value, string fallback)
        {
            return string.IsNullOrWhiteSpace(value) ? fallback : value.Trim();
        }

        private static int Seconds(string value, int fallback, int min, int max)
        {
            int parsed;
            if (!int.TryParse(value, out parsed)) return fallback;
            return Math.Max(min, Math.Min(max, parsed));
        }
    }
}
