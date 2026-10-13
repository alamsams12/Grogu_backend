using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// Matching testers and playtests.
    ///
    /// <list type="bullet">
    /// <item><c>/api/v1/playtests/{id}/suggestions</c> — testers who fit a recruiting
    ///   playtest, for the studio that owns it.</item>
    /// <item><c>/api/v1/playtests/{id}/invites</c> — the studio invites one of them.</item>
    /// <item><c>/api/v1/recommendations</c> — open playtests that fit the signed-in tester.</item>
    /// </list>
    ///
    /// Eligibility and scores come from the rules in SQL (<c>grogu_match_candidates</c>).
    /// <c>GET</c> never calls the AI. <c>POST</c> asks Gemini to re-order the
    /// rule-based shortlist and explain each entry, but only when the shortlist
    /// has changed since the last AI ranking; when Gemini is off or fails, the
    /// rule order is returned with a notice saying why.
    /// </summary>
    [ApiController]
    [Authorize]
    public class MatchingV1Controller : ApiControllerBase
    {
        private readonly GeminiClient _gemini;

        public MatchingV1Controller(GroguDb db, GeminiClient gemini) : base(db)
        {
            _gemini = gemini;
        }

        /* ------------------------------------------------------------------ */
        /*  Studio side                                                       */
        /* ------------------------------------------------------------------ */

        [HttpGet("api/v1/playtests/{id:int}/suggestions")]
        public Task<IActionResult> GetSuggestions(int id)
        {
            return SuggestionsView(id, null);
        }

        [HttpPost("api/v1/playtests/{id:int}/suggestions")]
        public async Task<IActionResult> RankSuggestions(int id)
        {
            var prepared = await Db.QueryJsonAsync(
                "SELECT grogu_tester_suggestions_prepare(@UserId, @PlaytestId)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id));

            if (prepared.Error != null)
            {
                return prepared.Error;
            }

            var notice = await RankAsync(prepared.Json, "studio", id, "match:studio:" + id, studioSide: true);
            return await SuggestionsView(id, notice);
        }

        /// <summary>Body: <c>{ "testerId": "12" }</c>. Inviting twice is harmless.</summary>
        [HttpPost("api/v1/playtests/{id:int}/invites")]
        public Task<IActionResult> Invite(int id, [FromBody] JsonElement body)
        {
            int testerId;
            if (!TryReadId(body, "testerId", out testerId))
            {
                return Task.FromResult(GroguDb.Error(400, "validation", "Choose a tester to invite."));
            }

            return Db.JsonAsync(
                "SELECT grogu_playtest_invite(@UserId, @PlaytestId, @TesterId)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id),
                GroguDb.Int("@TesterId", testerId));
        }

        /* ------------------------------------------------------------------ */
        /*  Tester side                                                       */
        /* ------------------------------------------------------------------ */

        [HttpGet("api/v1/recommendations")]
        public Task<IActionResult> GetRecommendations()
        {
            return RecommendationsView(null);
        }

        [HttpPost("api/v1/recommendations")]
        public async Task<IActionResult> RankRecommendations()
        {
            var prepared = await Db.QueryJsonAsync(
                "SELECT grogu_playtest_recommendations_prepare(@UserId)",
                GroguDb.Int("@UserId", CurrentUserId));

            if (prepared.Error != null)
            {
                return prepared.Error;
            }

            var userId = CurrentUserId ?? 0;
            var notice = await RankAsync(prepared.Json, "tester", userId, "match:tester:" + userId, studioSide: false);
            return await RecommendationsView(notice);
        }

        /* ------------------------------------------------------------------ */
        /*  Shared                                                            */
        /* ------------------------------------------------------------------ */

        /// <summary>
        /// Asks Gemini to rank the prepared shortlist and stores the answer.
        /// Returns a notice when no fresh AI ranking was produced, otherwise null.
        /// </summary>
        private async Task<string> RankAsync(string preparedJson, string kind, int subjectId, string rateKey, bool studioSide)
        {
            using (var doc = JsonDocument.Parse(preparedJson))
            {
                var root = doc.RootElement;

                // Nothing changed since the last AI ranking, or nothing to rank.
                if (!root.GetProperty("stale").GetBoolean())
                {
                    return null;
                }

                if (!_gemini.IsConfigured)
                {
                    return AiNotices.For(GeminiFailure.NotConfigured, AiTask.Ranking);
                }

                System.Collections.Generic.Dictionary<string, string> keyToId;
                var content = studioSide
                    ? MatchPrompt.BuildStudioContent(root, out keyToId)
                    : MatchPrompt.BuildTesterContent(root, out keyToId);

                var result = await _gemini.GenerateJsonAsync(
                    rateKey,
                    studioSide ? MatchPrompt.StudioInstruction : MatchPrompt.TesterInstruction,
                    content,
                    MatchPrompt.Schema);

                if (!result.Ok)
                {
                    return AiNotices.For(result.Failure, AiTask.Ranking);
                }

                var ranking = MatchPrompt.CleanRanking(result.Json, keyToId);
                if (ranking == null)
                {
                    return AiNotices.For(GeminiFailure.BadResponse, AiTask.Ranking);
                }

                // Stored against the fingerprint read BEFORE the model ran, so a
                // shortlist that changed meanwhile is not given a stale ranking.
                var stored = await Db.QueryJsonAsync(
                    "SELECT grogu_match_store(@UserId, @Kind, @SubjectId, @Fingerprint, @Ranking, @Model)",
                    GroguDb.Int("@UserId", CurrentUserId),
                    GroguDb.Text("@Kind", kind),
                    GroguDb.Int("@SubjectId", subjectId),
                    GroguDb.Text("@Fingerprint", root.GetProperty("fingerprint").GetString()),
                    GroguDb.Json("@Ranking", ranking),
                    GroguDb.Text("@Model", result.Model));

                return stored.Error != null ? AiNotices.For(GeminiFailure.BadResponse, AiTask.Ranking) : null;
            }
        }

        private Task<IActionResult> SuggestionsView(int id, string notice)
        {
            return Db.JsonAsync(
                "SELECT grogu_tester_suggestions_view(@UserId, @PlaytestId, @Notice, @AiEnabled)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id),
                GroguDb.Text("@Notice", notice),
                GroguDb.Bool("@AiEnabled", _gemini.IsConfigured));
        }

        private Task<IActionResult> RecommendationsView(string notice)
        {
            return Db.JsonAsync(
                "SELECT grogu_playtest_recommendations_view(@UserId, @Notice, @AiEnabled)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Text("@Notice", notice),
                GroguDb.Bool("@AiEnabled", _gemini.IsConfigured));
        }

        /// <summary>An id sent as a string ("12") or a number (12).</summary>
        private static bool TryReadId(JsonElement body, string name, out int id)
        {
            id = 0;
            JsonElement value;
            if (body.ValueKind != JsonValueKind.Object || !body.TryGetProperty(name, out value))
            {
                return false;
            }
            if (value.ValueKind == JsonValueKind.Number)
            {
                return value.TryGetInt32(out id) && id > 0;
            }
            return value.ValueKind == JsonValueKind.String && int.TryParse(value.GetString(), out id) && id > 0;
        }
    }
}
