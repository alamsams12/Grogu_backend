namespace Grogu.Infrastructure
{
    /// <summary>What an AI-backed feature was trying to do, for the wording of its notices.</summary>
    public enum AiTask
    {
        Summary,
        Ranking
    }

    /// <summary>
    /// The user-facing reason a fresh AI result was not produced. Shown next to
    /// the fallback, so it says what went wrong, not what is shown instead.
    /// </summary>
    public static class AiNotices
    {
        public static string For(GeminiFailure failure, AiTask task)
        {
            var feature = task == AiTask.Summary ? "AI summaries" : "AI rankings";

            switch (failure)
            {
                case GeminiFailure.NotConfigured:
                    return feature + " aren't switched on for this server.";
                case GeminiFailure.RateLimited:
                    return feature + " are limited to stay within the free quota. Try again in a minute.";
                case GeminiFailure.CoolingDown:
                    return "The last AI attempt didn't finish. Try again in a minute.";
                case GeminiFailure.Busy:
                    return "The AI service is busy. Try again in a moment.";
                case GeminiFailure.Blocked:
                    return task == AiTask.Summary
                        ? "The AI service declined to summarise this feedback."
                        : "The AI service declined to rank this list.";
                case GeminiFailure.BadResponse:
                    return "The AI service returned something unusable. Try again shortly.";
                default:
                    return "The AI service didn't respond. Try again shortly.";
            }
        }
    }
}
