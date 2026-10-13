using System;
using System.IO;
using System.Threading.Tasks;
using CloudinaryDotNet;
using CloudinaryDotNet.Actions;
using Microsoft.Extensions.Configuration;

namespace Grogu.Infrastructure
{
    /// <summary>
    /// Stores uploads in Cloudinary and returns the permanent HTTPS delivery URL,
    /// so files survive redeploys of the (ephemeral-disk) API host.
    ///
    /// Configure with either <c>CLOUDINARY_URL</c>
    /// (<c>cloudinary://key:secret@cloud</c>) or the three settings
    /// <c>Cloudinary__CloudName</c>, <c>Cloudinary__ApiKey</c>, <c>Cloudinary__ApiSecret</c>.
    /// When neither is present the app keeps using <see cref="LocalFileStore"/>.
    /// </summary>
    public class CloudinaryFileStore : IFileStore
    {
        private const string Folder = "grogu";

        private readonly Cloudinary _cloudinary;

        public CloudinaryFileStore(Cloudinary cloudinary)
        {
            _cloudinary = cloudinary;
            _cloudinary.Api.Secure = true;
        }

        /// <summary>Returns null when Cloudinary is not configured.</summary>
        public static Cloudinary TryCreateClient(IConfiguration configuration)
        {
            var url = configuration["CLOUDINARY_URL"];
            if (!string.IsNullOrWhiteSpace(url))
            {
                return new Cloudinary(url);
            }

            var cloud = configuration["Cloudinary:CloudName"];
            var key = configuration["Cloudinary:ApiKey"];
            var secret = configuration["Cloudinary:ApiSecret"];
            if (string.IsNullOrWhiteSpace(cloud) || string.IsNullOrWhiteSpace(key) || string.IsNullOrWhiteSpace(secret))
            {
                return null;
            }

            return new Cloudinary(new Account(cloud, key, secret));
        }

        public async Task<string> SaveAsync(Stream content, string extension)
        {
            // The extension is chosen by the controller from its allow-list.
            var name = Guid.NewGuid().ToString("N");
            var isVideo = extension == ".mp4" || extension == ".webm";
            var file = new FileDescription(name + extension, content);

            UploadResult result;
            if (isVideo)
            {
                result = await _cloudinary.UploadLargeAsync(new VideoUploadParams
                {
                    File = file,
                    PublicId = name,
                    Folder = Folder,
                    UseFilename = false,
                    UniqueFilename = false,
                    Overwrite = false
                });
            }
            else
            {
                result = await _cloudinary.UploadAsync(new ImageUploadParams
                {
                    File = file,
                    PublicId = name,
                    Folder = Folder,
                    UseFilename = false,
                    UniqueFilename = false,
                    Overwrite = false
                });
            }

            if (result.Error != null || result.SecureUrl == null)
            {
                // Message only: never log the account credentials.
                throw new InvalidOperationException(
                    "File storage failed: " + (result.Error?.Message ?? "no URL returned") + ".");
            }

            return result.SecureUrl.ToString();
        }
    }
}
