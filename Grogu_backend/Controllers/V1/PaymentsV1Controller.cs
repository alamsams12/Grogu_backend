using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// Funding a playtest's cash reward pool with Razorpay.
    ///
    /// <list type="number">
    /// <item><c>POST /api/v1/payments/orders</c> <c>{ playtestId, amount }</c> (whole rupees):
    ///   the database checks ownership and the amount and records the order, then
    ///   the order is created with Razorpay. Returns what Checkout needs.</item>
    /// <item>The browser opens Razorpay Checkout with the returned key id and order id.</item>
    /// <item><c>POST /api/v1/payments/verify</c> <c>{ razorpayOrderId, razorpayPaymentId,
    ///   razorpaySignature }</c>: the signature is checked with the key secret and the pool
    ///   is credited the amount stored in step 1.</item>
    /// <item><c>POST /api/v1/payments/webhook</c>: Razorpay's server-to-server notice
    ///   (<c>payment.captured</c>, <c>order.paid</c>, <c>payment.failed</c>), checked
    ///   with the webhook secret. It credits the pool if the browser never came
    ///   back, and is a no-op when step 3 already did.</item>
    /// </list>
    ///
    /// The amount credited always comes from the database row, never from the
    /// browser, and an order is credited at most once.
    /// </summary>
    [ApiController]
    [Authorize]
    public class PaymentsV1Controller : ApiControllerBase
    {
        private readonly RazorpayClient _razorpay;
        private readonly ILogger<PaymentsV1Controller> _logger;

        public PaymentsV1Controller(GroguDb db, RazorpayClient razorpay, ILogger<PaymentsV1Controller> logger)
            : base(db)
        {
            _razorpay = razorpay;
            _logger = logger;
        }

        /// <summary>Whether payments are available, so the UI can hide or explain the button.</summary>
        [HttpGet("api/v1/payments/config")]
        [AllowAnonymous]
        public IActionResult Config()
        {
            return Ok(new
            {
                enabled = _razorpay.IsConfigured,
                testMode = _razorpay.IsConfigured && _razorpay.TestMode,
                keyId = _razorpay.IsConfigured ? _razorpay.KeyId : null
            });
        }

        [HttpPost("api/v1/payments/orders")]
        public async Task<IActionResult> CreateOrder([FromBody] JsonElement body)
        {
            if (!_razorpay.IsConfigured)
            {
                return NotConfigured();
            }

            var prepared = await Db.QueryJsonAsync(
                "SELECT grogu_payment_order_prepare(@UserId, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Json("@Input", BodyJson(body)));
            if (prepared.Error != null)
            {
                return prepared.Error;
            }

            int orderRowId;
            long amountPaise;
            string currency, receipt, playtestId, playtestTitle;
            int amount;
            using (var doc = JsonDocument.Parse(prepared.Json))
            {
                var root = doc.RootElement;
                orderRowId = int.Parse(root.GetProperty("id").GetString());
                amount = root.GetProperty("amount").GetInt32();
                amountPaise = root.GetProperty("amountPaise").GetInt64();
                currency = root.GetProperty("currency").GetString();
                receipt = root.GetProperty("receipt").GetString();
                playtestId = root.GetProperty("playtestId").GetString();
                playtestTitle = root.GetProperty("playtestTitle").GetString();
            }

            var created = await _razorpay.CreateOrderAsync(
                amountPaise, currency, receipt, playtestId, CurrentUserId.ToString());

            if (!created.Ok)
            {
                await Db.QueryJsonAsync(
                    "SELECT grogu_payment_order_fail(@Id, @Reason)::text",
                    GroguDb.Int("@Id", orderRowId),
                    GroguDb.Text("@Reason", created.Error));
                return GroguDb.Error(502, "server-error",
                    "Couldn't start the payment with Razorpay. Please try again in a moment.");
            }

            var attached = await Db.QueryJsonAsync(
                "SELECT grogu_payment_order_attach(@UserId, @Id, @OrderId)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@Id", orderRowId),
                GroguDb.Text("@OrderId", created.OrderId));
            if (attached.Error != null)
            {
                return attached.Error;
            }

            return Ok(new
            {
                orderId = orderRowId.ToString(),
                razorpayOrderId = created.OrderId,
                keyId = _razorpay.KeyId,
                amount = amount,
                amountPaise = amountPaise,
                currency = currency,
                playtestId = playtestId,
                description = "Reward pool: " + playtestTitle,
                testMode = _razorpay.TestMode
            });
        }

        [HttpPost("api/v1/payments/verify")]
        public async Task<IActionResult> Verify([FromBody] JsonElement body)
        {
            if (!_razorpay.IsConfigured)
            {
                return NotConfigured();
            }

            var orderId = StringField(body, "razorpayOrderId");
            var paymentId = StringField(body, "razorpayPaymentId");
            var signature = StringField(body, "razorpaySignature");

            if (!_razorpay.VerifyPaymentSignature(orderId, paymentId, signature))
            {
                return GroguDb.Error(400, "validation",
                    "We couldn't verify this payment. If you were charged, it will be added automatically once Razorpay confirms it.");
            }

            return await Db.JsonAsync(
                "SELECT grogu_payment_capture(@UserId, @OrderId, @PaymentId, NULL)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Text("@OrderId", orderId),
                GroguDb.Text("@PaymentId", paymentId));
        }

        /// <summary>
        /// Razorpay webhook. Configure it in the dashboard with this URL, the same
        /// secret as <c>Razorpay__WebhookSecret</c>, and the events
        /// <c>payment.captured</c>, <c>order.paid</c> and <c>payment.failed</c>.
        ///
        /// Answers 200 for anything it has handled or deliberately ignores, so
        /// Razorpay doesn't retry; 400 for a bad signature; 5xx only when the
        /// database failed, so Razorpay retries later.
        /// </summary>
        [HttpPost("api/v1/payments/webhook")]
        [AllowAnonymous]
        public async Task<IActionResult> Webhook()
        {
            if (!_razorpay.WebhookConfigured)
            {
                return GroguDb.Error(503, "server-error", "Webhooks are not configured.");
            }

            string raw;
            using (var reader = new StreamReader(Request.Body, Encoding.UTF8))
            {
                raw = await reader.ReadToEndAsync();
            }

            var signature = Request.Headers["X-Razorpay-Signature"].ToString();
            if (!_razorpay.VerifyWebhookSignature(raw, signature))
            {
                _logger.LogWarning("Rejected a Razorpay webhook with an invalid signature.");
                return GroguDb.Error(400, "validation", "Invalid signature.");
            }

            string evt, orderId = null, paymentId = null, reason = null;
            long? amountPaise = null;
            try
            {
                using (var doc = JsonDocument.Parse(raw))
                {
                    var root = doc.RootElement;
                    evt = root.GetProperty("event").GetString();

                    JsonElement payload, payment, entity, order;
                    if (root.TryGetProperty("payload", out payload))
                    {
                        if (payload.TryGetProperty("payment", out payment) && payment.TryGetProperty("entity", out entity))
                        {
                            paymentId = StringField(entity, "id");
                            orderId = StringField(entity, "order_id");
                            JsonElement amt;
                            if (entity.TryGetProperty("amount", out amt) && amt.ValueKind == JsonValueKind.Number)
                            {
                                amountPaise = amt.GetInt64();
                            }
                            reason = StringField(entity, "error_description");
                        }
                        if (orderId == null && payload.TryGetProperty("order", out order)
                            && order.TryGetProperty("entity", out entity))
                        {
                            orderId = StringField(entity, "id");
                        }
                    }
                }
            }
            catch (JsonException)
            {
                return GroguDb.Error(400, "validation", "Unreadable payload.");
            }
            catch (System.Collections.Generic.KeyNotFoundException)
            {
                return GroguDb.Error(400, "validation", "Unreadable payload.");
            }

            if (string.IsNullOrEmpty(orderId))
            {
                return Ok(new { ignored = true });
            }

            if (evt == "payment.failed")
            {
                await Db.QueryJsonAsync(
                    "SELECT grogu_payment_attempt_failed(@OrderId, @Reason)::text",
                    GroguDb.Text("@OrderId", orderId),
                    GroguDb.Text("@Reason", reason ?? "Payment failed."));
                return Ok(new { handled = true });
            }

            if (evt != "payment.captured" && evt != "order.paid")
            {
                return Ok(new { ignored = true });
            }

            var captured = await Db.QueryJsonAsync(
                "SELECT grogu_payment_capture(NULL, @OrderId, @PaymentId, @Amount)",
                GroguDb.Text("@OrderId", orderId),
                GroguDb.Text("@PaymentId", paymentId),
                new Npgsql.NpgsqlParameter("@Amount", NpgsqlTypes.NpgsqlDbType.Bigint)
                {
                    Value = amountPaise.HasValue ? (object)amountPaise.Value : System.DBNull.Value
                });

            if (captured.Error != null)
            {
                var status = (captured.Error as ObjectResult)?.StatusCode ?? 500;
                // An order that isn't ours (another app on the same Razorpay account)
                // or a mismatched amount won't get better with retries: log and accept.
                if (status == 404 || status == 400)
                {
                    _logger.LogWarning("Razorpay webhook for order {OrderId} not applied (HTTP {Status}).", orderId, status);
                    return Ok(new { ignored = true });
                }
                return captured.Error;
            }

            return Ok(new { handled = true });
        }

        /// <summary>The studio's pool summary, entries and orders for one playtest.</summary>
        [HttpGet("api/v1/playtests/{id:int}/reward-pool")]
        public Task<IActionResult> Pool(int id)
        {
            return Db.JsonAsync(
                "SELECT grogu_reward_pool_view(@UserId, @PlaytestId)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id));
        }

        private static IActionResult NotConfigured()
        {
            return GroguDb.Error(503, "server-error", "Payments aren't set up on this server yet.");
        }

        private static string StringField(JsonElement obj, string name)
        {
            JsonElement value;
            if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out value)
                && value.ValueKind == JsonValueKind.String)
            {
                var s = value.GetString().Trim();
                return s.Length == 0 || s.Length > 200 ? null : s;
            }
            return null;
        }
    }
}
