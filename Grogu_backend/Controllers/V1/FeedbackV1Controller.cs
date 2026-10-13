using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// A studio's decision on a submitted review, for the frontend's
    /// <c>lib/services/feedback.ts</c>.
    ///
    /// Approving pays the tester whatever mix of reputation, money and a game key
    /// the studio picks. Ownership, the once-only rule and key allocation are all
    /// enforced in <c>grogu_feedback_review</c>, in one transaction.
    /// </summary>
    [ApiController]
    [Route("api/v1/feedback")]
    [Authorize]
    public class FeedbackV1Controller : ApiControllerBase
    {
        public FeedbackV1Controller(GroguDb db) : base(db) { }

        [HttpPost("{id:int}/review")]
        public Task<IActionResult> Review(int id, [FromBody] JsonElement body)
        {
            return Db.JsonAsync(
                "SELECT grogu_feedback_review(@UserId, @FeedbackId, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@FeedbackId", id),
                GroguDb.Json("@Input", BodyJson(body)));
        }
    }
}
