using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// A game's public page (<c>/games/{slug}</c> in the frontend): details, links,
    /// ratings, reviews and open playtests, plus the two things any visitor can do
    /// there: report a bug and review the game.
    ///
    /// Every endpoint works signed in or anonymously. A bearer token, when sent,
    /// is still read, so a signed-in visitor's report is linked to their account
    /// (and can earn reputation) and their review is the one they can edit.
    ///
    /// Anonymous posts are rate-limited per hashed client IP in the database, must
    /// leave the hidden <c>website</c> field empty (bots fill every field), and
    /// need a Turnstile token when <c>Turnstile__SecretKey</c> is configured.
    /// </summary>
    [ApiController]
    [Route("api/v1/public/games/{slug}")]
    [AllowAnonymous]
    public class PublicGamesV1Controller : ApiControllerBase
    {
        private readonly AbuseGuard _guard;

        public PublicGamesV1Controller(GroguDb db, AbuseGuard guard) : base(db)
        {
            _guard = guard;
        }

        [HttpGet]
        public Task<IActionResult> Get(string slug)
        {
            return Db.JsonAsync(
                "SELECT grogu_game_public(@Slug, @UserId)",
                GroguDb.Text("@Slug", Clip(slug)),
                GroguDb.Int("@UserId", CurrentUserId));
        }

        [HttpPost("bugs")]
        public async Task<IActionResult> ReportBug(string slug, [FromBody] JsonElement body)
        {
            var refused = await Screen(body);
            if (refused != null)
            {
                return refused;
            }

            return await Db.JsonAsync(
                "SELECT grogu_bug_report_create(@UserId, @Slug, @Input, @IpHash)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Text("@Slug", Clip(slug)),
                GroguDb.Json("@Input", BodyJson(body)),
                GroguDb.Text("@IpHash", _guard.ClientHash(HttpContext)));
        }

        [HttpPost("reviews")]
        public async Task<IActionResult> Review(string slug, [FromBody] JsonElement body)
        {
            var refused = await Screen(body);
            if (refused != null)
            {
                return refused;
            }

            return await Db.JsonAsync(
                "SELECT grogu_game_review_save(@UserId, @Slug, @Input, @IpHash)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Text("@Slug", Clip(slug)),
                GroguDb.Json("@Input", BodyJson(body)),
                GroguDb.Text("@IpHash", _guard.ClientHash(HttpContext)));
        }

        /// <summary>The honeypot and (for anonymous callers) the captcha. Null when the post may go on.</summary>
        private async Task<IActionResult> Screen(JsonElement body)
        {
            if (body.ValueKind != JsonValueKind.Object)
            {
                return GroguDb.Error(400, "validation", "Send the form as JSON.");
            }

            JsonElement trap;
            if (body.TryGetProperty("website", out trap) && trap.ValueKind == JsonValueKind.String
                && trap.GetString().Length > 0)
            {
                return GroguDb.Error(400, "validation", "Couldn't send that. Please try again.");
            }

            if (CurrentUserId == null && _guard.CaptchaRequired)
            {
                JsonElement token;
                var value = body.TryGetProperty("captchaToken", out token) && token.ValueKind == JsonValueKind.String
                    ? token.GetString()
                    : null;

                if (!await _guard.VerifyCaptchaAsync(value, AbuseGuard.ClientIp(HttpContext)))
                {
                    return GroguDb.Error(400, "validation", "Please complete the human check, or sign in.");
                }
            }

            return null;
        }

        private static string Clip(string slug)
        {
            if (slug == null)
            {
                return null;
            }
            return slug.Length > 80 ? slug.Substring(0, 80) : slug;
        }
    }
}
