using System;
using System.IO;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;

namespace Grogu.Infrastructure
{
    /// <summary>
    /// Where uploaded files (game posters, review screenshots and recordings) are
    /// kept. The rest of the app only sees the returned URL, so a hosted provider
    /// (Cloudinary, R2, S3) can replace <see cref="LocalFileStore"/> without
    /// touching the controllers or the database.
    /// </summary>
    public interface IFileStore
    {
        /// <summary>
        /// Saves the content under a generated name and returns the URL it is served
        /// from. <paramref name="extension"/> comes from the caller's allow-list, never
        /// from the uploaded file name.
        /// </summary>
        Task<string> SaveAsync(Stream content, string extension);
    }

    /// <summary>
    /// Keeps files on local disk and serves them from <c>/uploads</c>. Intended for
    /// development: on a host with an ephemeral filesystem (Render's default) the
    /// files disappear on redeploy, so production needs a persistent disk or a
    /// hosted <see cref="IFileStore"/>.
    /// </summary>
    public class LocalFileStore : IFileStore
    {
        private readonly string _root;

        public LocalFileStore(IConfiguration configuration, IWebHostEnvironment environment)
        {
            _root = ResolveRoot(configuration, environment);
            Directory.CreateDirectory(_root);
        }

        /// <summary>
        /// <c>Storage__Path</c> if set, otherwise an <c>uploads</c> folder next to the
        /// app. Shared with Startup so the folder that is written is the one served.
        /// </summary>
        public static string ResolveRoot(IConfiguration configuration, IWebHostEnvironment environment)
        {
            var configured = configuration["Storage:Path"];
            return string.IsNullOrWhiteSpace(configured)
                ? Path.Combine(environment.ContentRootPath, "uploads")
                : configured;
        }

        public async Task<string> SaveAsync(Stream content, string extension)
        {
            var name = Guid.NewGuid().ToString("N") + extension;
            var path = Path.Combine(_root, name);

            using (var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                await content.CopyToAsync(file);
            }

            return "/uploads/" + name;
        }
    }
}
