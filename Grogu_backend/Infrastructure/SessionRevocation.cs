using System;
using System.Collections.Concurrent;
using System.Threading.Tasks;

namespace Grogu.Infrastructure
{
    /// <summary>
    /// Bearer tokens are stateless, so a password reset can't delete them. Instead
    /// each request's token must have been issued (its <c>nbf</c>) no earlier than
    /// the user's last password change; older tokens are rejected, which signs
    /// every other device out after a reset.
    ///
    /// The change time is cached per user for a short while to avoid a database
    /// round trip on every request. A reset evicts the user's entry on this
    /// instance; other instances notice within <see cref="CacheFor"/>.
    /// </summary>
    public class SessionRevocation
    {
        private static readonly TimeSpan CacheFor = TimeSpan.FromSeconds(60);

        private readonly GroguDb _db;
        private readonly ConcurrentDictionary<int, (long ChangedEpoch, DateTime FetchedAt)> _cache =
            new ConcurrentDictionary<int, (long, DateTime)>();

        public SessionRevocation(GroguDb db)
        {
            _db = db;
        }

        /// <summary>True if a token issued at <paramref name="issuedAtUtc"/> is still acceptable.</summary>
        public async Task<bool> IsCurrentAsync(int userId, DateTime issuedAtUtc)
        {
            (long ChangedEpoch, DateTime FetchedAt) entry;
            if (!_cache.TryGetValue(userId, out entry) || DateTime.UtcNow - entry.FetchedAt > CacheFor)
            {
                var result = await _db.QueryJsonAsync(
                    "SELECT grogu_password_changed_epoch(@UserId)::text",
                    GroguDb.Int("@UserId", userId));

                if (result.Error != null)
                {
                    // No such user (deleted account): reject. Any other failure is a
                    // database problem; let the request through rather than signing
                    // everyone out during a blip. The endpoints themselves still hit
                    // the database and fail on their own if it is really down.
                    var status = (result.Error as Microsoft.AspNetCore.Mvc.ObjectResult)?.StatusCode;
                    return status != 404;
                }

                long changed;
                if (!long.TryParse(result.Json, out changed))
                {
                    return true;
                }

                entry = (changed, DateTime.UtcNow);
                _cache[userId] = entry;
            }

            var issuedEpoch = new DateTimeOffset(DateTime.SpecifyKind(issuedAtUtc, DateTimeKind.Utc)).ToUnixTimeSeconds();
            return issuedEpoch >= entry.ChangedEpoch;
        }

        public void Forget(int userId)
        {
            (long, DateTime) ignored;
            _cache.TryRemove(userId, out ignored);
        }
    }
}
