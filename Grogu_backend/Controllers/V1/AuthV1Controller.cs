using System;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// Sign-up, sign-in and session for the frontend's <c>lib/services/auth.ts</c>.
    ///
    /// Replaces <c>/api/auth</c>, which took form fields, compared passwords in
    /// plaintext and issued no credential at all. Responses carry a bearer token
    /// plus the <c>User</c> the frontend's <c>Session</c> is built from.
    /// </summary>
    [ApiController]
    [Route("api/v1/auth")]
    public class AuthV1Controller : ApiControllerBase
    {
        private readonly JwtTokenService _jwt;
        private readonly EmailSender _email;
        private readonly AbuseGuard _guard;
        private readonly SessionRevocation _revocation;

        public AuthV1Controller(GroguDb db, JwtTokenService jwt, EmailSender email, AbuseGuard guard,
            SessionRevocation revocation) : base(db)
        {
            _jwt = jwt;
            _email = email;
            _guard = guard;
            _revocation = revocation;
        }

        [HttpPost("signup")]
        [AllowAnonymous]
        public async Task<IActionResult> Signup([FromBody] JsonElement body)
        {
            var result = await Db.QueryJsonAsync(
                "SELECT grogu_signup(@Input)",
                GroguDb.Json("@Input", BodyJson(body)));

            return result.Error ?? SessionResponse(result.Json, 201);
        }

        [HttpPost("login")]
        [AllowAnonymous]
        public async Task<IActionResult> Login([FromBody] JsonElement body)
        {
            string email = null;
            string password = null;

            JsonElement value;
            if (body.ValueKind == JsonValueKind.Object)
            {
                if (body.TryGetProperty("email", out value) && value.ValueKind == JsonValueKind.String)
                {
                    email = value.GetString();
                }
                if (body.TryGetProperty("password", out value) && value.ValueKind == JsonValueKind.String)
                {
                    password = value.GetString();
                }
            }

            if (string.IsNullOrWhiteSpace(email) || string.IsNullOrEmpty(password))
            {
                return GroguDb.Error(400, "validation", "Enter your email and password.");
            }

            var result = await Db.QueryJsonAsync(
                "SELECT grogu_login(@Email, @Password)",
                GroguDb.Text("@Email", email),
                GroguDb.Text("@Password", password));

            return result.Error ?? SessionResponse(result.Json, 200);
        }

        /// <summary>
        /// Re-reads the caller's own user record. The frontend calls this on load to
        /// find out whether a stored token is still valid.
        /// </summary>
        [HttpGet("session")]
        [Authorize]
        public async Task<IActionResult> Session()
        {
            var userId = CurrentUserId;
            if (userId == null)
            {
                return GroguDb.Error(401, "invalid-credentials", "Not signed in.");
            }

            return await Db.JsonAsync(
                "SELECT grogu_bootstrap(@UserId) -> 'session'",
                GroguDb.Int("@UserId", userId));
        }

        /// <summary>
        /// Tokens are stateless and self-expiring, so there is nothing to revoke
        /// server-side; the frontend discards its copy. The endpoint exists so the
        /// client has one call to make and a place to hang revocation later.
        /// </summary>
        [HttpPost("logout")]
        [AllowAnonymous]
        public IActionResult Logout()
        {
            return Ok(new { message = "Signed out." });
        }

        /// <summary>
        /// Starts a password reset. Body: <c>{ email }</c>. Always answers the same
        /// way, whether or not the address has an account, and sends the email in
        /// the background so the response time doesn't tell either.
        /// </summary>
        [HttpPost("forgot-password")]
        [AllowAnonymous]
        public async Task<IActionResult> ForgotPassword([FromBody] JsonElement body)
        {
            var email = StringField(body, "email");
            if (string.IsNullOrWhiteSpace(email) || email.Length > 254 || !email.Contains("@"))
            {
                return GroguDb.Error(400, "validation", "Enter the email address you signed up with.");
            }

            var token = NewToken();
            var result = await Db.QueryJsonAsync(
                "SELECT grogu_password_reset_request(@Email, @Hash, @IpHash)",
                GroguDb.Text("@Email", email.Trim()),
                GroguDb.Text("@Hash", Sha256Hex(token)),
                GroguDb.Text("@IpHash", _guard.ClientHash(HttpContext)));

            if (result.Error == null)
            {
                using (var doc = JsonDocument.Parse(result.Json))
                {
                    var root = doc.RootElement;
                    if (root.GetProperty("send").GetBoolean())
                    {
                        var to = root.GetProperty("email").GetString();
                        var name = root.GetProperty("name").GetString();
                        var link = _email.FrontendUrl + "/reset-password?token=" + token;
                        // Not awaited: see the summary. SendAsync never throws.
                        _ = _email.SendPasswordResetAsync(to, name, link);
                    }
                }
            }

            return Ok(new
            {
                message = "If an account uses that email, we've sent a link to reset the password. It works for 30 minutes."
            });
        }

        /// <summary>Finishes a reset. Body: <c>{ token, password }</c>. Signs out every other session.</summary>
        [HttpPost("reset-password")]
        [AllowAnonymous]
        public async Task<IActionResult> ResetPassword([FromBody] JsonElement body)
        {
            var token = StringField(body, "token");
            var password = body.ValueKind == JsonValueKind.Object && body.TryGetProperty("password", out var p)
                           && p.ValueKind == JsonValueKind.String ? p.GetString() : null;

            if (string.IsNullOrEmpty(token) || token.Length > 128)
            {
                return GroguDb.Error(400, "validation", "This reset link is invalid or has expired. Ask for a new one.");
            }

            var result = await Db.QueryJsonAsync(
                "SELECT grogu_password_reset_complete(@Hash, @Password)",
                GroguDb.Text("@Hash", Sha256Hex(token)),
                GroguDb.Text("@Password", password ?? string.Empty));
            if (result.Error != null)
            {
                return result.Error;
            }

            using (var doc = JsonDocument.Parse(result.Json))
            {
                _revocation.Forget(doc.RootElement.GetProperty("userId").GetInt32());
            }

            return Ok(new { message = "Your password has been changed. Sign in with the new one." });
        }

        private static string StringField(JsonElement body, string name)
        {
            JsonElement value;
            return body.ValueKind == JsonValueKind.Object && body.TryGetProperty(name, out value)
                   && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
        }

        /// <summary>32 random bytes, URL-safe base64 (43 characters).</summary>
        private static string NewToken()
        {
            var bytes = new byte[32];
            using (var rng = RandomNumberGenerator.Create())
            {
                rng.GetBytes(bytes);
            }
            return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        }

        private static string Sha256Hex(string value)
        {
            using (var sha = SHA256.Create())
            {
                var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(value));
                var sb = new StringBuilder(64);
                foreach (var b in hash)
                {
                    sb.Append(b.ToString("x2"));
                }
                return sb.ToString();
            }
        }

        /// <summary>Wraps a user document from the database in a signed session.</summary>
        private IActionResult SessionResponse(string userJson, int statusCode)
        {
            using (var document = JsonDocument.Parse(userJson))
            {
                var user = document.RootElement;

                int userId;
                if (!int.TryParse(user.GetProperty("id").GetString(), out userId))
                {
                    return GroguDb.Error(500, "server-error", "Could not establish a session.");
                }

                var role = user.GetProperty("role").GetString();

                DateTime expiresAt;
                var token = _jwt.Issue(userId, role, out expiresAt);

                return new ObjectResult(new
                {
                    token,
                    expiresAt = expiresAt.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"),
                    user = JsonSerializer.Deserialize<JsonElement>(userJson),
                    role
                })
                { StatusCode = statusCode };
            }
        }
    }
}
