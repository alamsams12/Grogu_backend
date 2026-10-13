using System.Text.Json;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// Playtests and the applications made to them, for the frontend's
    /// <c>lib/services/playtests.ts</c> and <c>lib/services/applications.ts</c>.
    ///
    /// The legacy <c>POST /api/playtests</c> accepted a studio id from the form
    /// body, so any caller could create a playtest under any studio. Ownership is
    /// now taken from the bearer token and checked in the stored function.
    /// </summary>
    [ApiController]
    [Route("api/v1/playtests")]
    [Authorize]
    public class PlaytestsV1Controller : ApiControllerBase
    {
        public PlaytestsV1Controller(GroguDb db) : base(db) { }

        [HttpPost]
        public Task<IActionResult> Create([FromBody] JsonElement body)
        {
            return Db.JsonAsync(
                "SELECT grogu_playtest_save(@UserId, NULL, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Json("@Input", BodyJson(body)));
        }

        [HttpPatch("{id:int}")]
        public Task<IActionResult> Update(int id, [FromBody] JsonElement body)
        {
            return Db.JsonAsync(
                "SELECT grogu_playtest_save(@UserId, @PlaytestId, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id),
                GroguDb.Json("@Input", BodyJson(body)));
        }

        /// <summary>
        /// Changes how testers get the game (build link, install notes, access key).
        /// Separate from <see cref="Update"/>, which only edits drafts, so a studio
        /// can fix a link after publishing.
        /// </summary>
        [HttpPatch("{id:int}/access")]
        public Task<IActionResult> SaveAccess(int id, [FromBody] JsonElement body)
        {
            return Db.JsonAsync(
                "SELECT grogu_playtest_access_save(@UserId, @PlaytestId, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id),
                GroguDb.Json("@Input", BodyJson(body)));
        }

        /// <summary>
        /// Moves a playtest along its lifecycle. The permitted transitions are the
        /// same table the frontend uses in <c>lib/domain.ts</c>, enforced server-side.
        /// </summary>
        [HttpPost("{id:int}/status")]
        public Task<IActionResult> SetStatus(int id, [FromBody] JsonElement body)
        {
            string status = null;
            JsonElement value;
            if (body.ValueKind == JsonValueKind.Object &&
                body.TryGetProperty("status", out value) &&
                value.ValueKind == JsonValueKind.String)
            {
                status = value.GetString();
            }

            if (string.IsNullOrWhiteSpace(status))
            {
                return Task.FromResult(GroguDb.Error(400, "validation", "A status is required."));
            }

            return Db.JsonAsync(
                "SELECT grogu_playtest_set_status(@UserId, @PlaytestId, @Status)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id),
                GroguDb.Text("@Status", status));
        }

        /// <summary>A tester applying to this playtest.</summary>
        [HttpPost("{id:int}/applications")]
        public Task<IActionResult> Apply(int id, [FromBody] JsonElement body)
        {
            return Db.JsonAsync(
                "SELECT grogu_application_create(@UserId, @PlaytestId, @Input)",
                GroguDb.Int("@UserId", CurrentUserId),
                GroguDb.Int("@PlaytestId", id),
                GroguDb.Json("@Input", BodyJson(body)));
        }
    }
}
