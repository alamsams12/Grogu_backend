using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// The studio's summary of a playtest's feedback: overall picture, highlights,
    /// what testers like and dislike, bugs and suggested next steps.
    ///
    /// <c>GET</c> never calls the AI. It returns the cached AI summary if there
    /// is one, otherwise a summary computed from the feedback in SQL. <c>POST</c>
    /// asks Gemini for a new summary, but only when feedback has arrived since the
    /// last one, and falls back to the same two sources whenever Gemini is off,
    /// rate-limited, slow or wrong. Neither can fail because of the AI.
    ///
    /// Only the studio that owns the playtest may call either (enforced in the
    /// stored functions).
    /// </summary>
    [ApiController]
    [Route("api/v1/playtests/{id:int}/insights")]
    [Authorize]
    public class InsightsV1Controller : ApiControllerBase
    {
        private readonly GeminiClient _gemini;

        public InsightsV1Controller(GroguDb db, GeminiClient gemini) : base(db)
        {
            _gemini = gemini;
        }

        [HttpGet]
        public Task<IActionResult> Get(int id)
        {
            return View(id, null);
        }

        [HttpPost]
        public async Task<IActionResult> Generate(int id)
        {
            var prepared = await Db.QueryJsonAsync(
                "SELECT grogu_insight_prepare(@UserId, @PlaytestId, true)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id));

            if (prepared.Error != null)
            {
                return prepared.Error;
            }

            using (var doc = JsonDocument.Parse(prepared.Json))
            {
                var root = doc.RootElement;

                // Nothing new since the last summary (or nothing to summarise): no call.
                if (!root.GetProperty("stale").GetBoolean())
                {
                    return await View(id, null);
                }

                if (!_gemini.IsConfigured)
                {
                    return await View(id, AiNotices.For(GeminiFailure.NotConfigured, AiTask.Summary));
                }

                var feedbackCount = root.GetProperty("feedbackCount").GetInt32();
                var lastFeedbackId = root.GetProperty("lastFeedbackId").GetInt32();

                var userContent = InsightPrompt.BuildUserContent(
                    root.GetProperty("title").GetString(),
                    root.GetProperty("gameTitle").GetString(),
                    root.GetProperty("genres"),
                    root.GetProperty("inputs"));

                var result = await _gemini.GenerateJsonAsync(
                    "insight:" + id, InsightPrompt.SystemInstruction, userContent, InsightPrompt.Schema);

                if (!result.Ok)
                {
                    return await View(id, AiNotices.For(result.Failure, AiTask.Summary));
                }

                var cleaned = InsightSanitizer.Clean(result.Json, feedbackCount);
                if (cleaned == null)
                {
                    return await View(id, AiNotices.For(GeminiFailure.BadResponse, AiTask.Summary));
                }

                // The counts stored are the ones read BEFORE the model ran, so a
                // review that arrived meanwhile keeps the summary marked stale.
                var stored = await Db.QueryJsonAsync(
                    "SELECT grogu_insight_store(@UserId, @PlaytestId, @Content, @Model, @Count, @LastId)",
                    GroguDb.Int("@UserId", CurrentUserId),
                    GroguDb.Int("@PlaytestId", id),
                    GroguDb.Json("@Content", cleaned),
                    GroguDb.Text("@Model", result.Model),
                    GroguDb.Int("@Count", feedbackCount),
                    GroguDb.Int("@LastId", lastFeedbackId));

                if (stored.Error != null)
                {
                    return await View(id, AiNotices.For(GeminiFailure.BadResponse, AiTask.Summary));
                }
            }

            return await View(id, null);
        }

        private Task<IActionResult> View(int id, string notice)
        {
            return Db.JsonAsync(
                "SELECT grogu_insight_view(@UserId, @PlaytestId, @Notice, @AiEnabled)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id),
                GroguDb.Text("@Notice", notice),
                GroguDb.Bool("@AiEnabled", _gemini.IsConfigured));
        }
    }
}
