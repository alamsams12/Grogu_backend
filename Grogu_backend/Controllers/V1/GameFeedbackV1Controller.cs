using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// What a studio does with the bug reports and reviews its game's public page
    /// collects. Ownership is enforced in the stored functions.
    /// </summary>
    [ApiController]
    [Authorize]
    public class GameFeedbackV1Controller : ApiControllerBase
    {
        public GameFeedbackV1Controller(GroguDb db) : base(db) { }

        /// <summary>
        /// Changes a report's status and/or note. Body: <c>{ status?, developerNote?, duplicateOf? }</c>.
        /// Confirming a signed-in tester's report awards them reputation once.
        /// </summary>
        [HttpPatch("api/v1/bugs/{id:int}")]
        public Task<IActionResult> UpdateBug(int id, [FromBody] JsonElement body)
        {
            return Db.JsonAsync(
                "SELECT grogu_bug_report_update(@UserId, @BugId, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@BugId", id),
                GroguDb.Json("@Input", BodyJson(body)));
        }

        /// <summary>The studio's public reply to a review. Body: <c>{ reply }</c>; empty removes it.</summary>
        [HttpPost("api/v1/reviews/{id:int}/reply")]
        public Task<IActionResult> Reply(int id, [FromBody] JsonElement body)
        {
            return Db.JsonAsync(
                "SELECT grogu_game_review_reply(@UserId, @ReviewId, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@ReviewId", id),
                GroguDb.Json("@Input", BodyJson(body)));
        }
    }
}
