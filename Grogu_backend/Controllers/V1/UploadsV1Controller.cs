using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Grogu.Infrastructure;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Grogu.Controllers.V1
{
    /// <summary>
    /// File uploads for game posters and review screenshots/recordings.
    ///
    /// The file's real type is read from its first bytes. The client's
    /// Content-Type and file name are never trusted: the stored extension comes
    /// from an allow-list, and SVG (which can carry script) is not on it.
    /// </summary>
    [ApiController]
    [Route("api/v1/uploads")]
    [Authorize]
    public class UploadsV1Controller : ApiControllerBase
    {
        private const long MaxRequestBytes = 55L * 1024 * 1024;
        private const long MB = 1024L * 1024;

        private sealed class Policy
        {
            public string Role; // null means any signed-in user
            public long ImageLimit;
            public long VideoLimit; // 0 means videos are not allowed for this kind
        }

        private static readonly Dictionary<string, Policy> Policies = new Dictionary<string, Policy>
        {
            { "poster",       new Policy { Role = "developer", ImageLimit = 5 * MB,  VideoLimit = 0 } },
            { "review-media", new Policy { Role = "tester",    ImageLimit = 10 * MB, VideoLimit = 50 * MB } },
            { "avatar",       new Policy { Role = null,        ImageLimit = 2 * MB,  VideoLimit = 0 } }
        };

        private readonly IFileStore _files;

        public UploadsV1Controller(GroguDb db, IFileStore files) : base(db)
        {
            _files = files;
        }

        [HttpPost]
        [RequestSizeLimit(MaxRequestBytes)]
        public async Task<IActionResult> Upload([FromQuery] string kind, IFormFile file)
        {
            Policy policy;
            if (string.IsNullOrWhiteSpace(kind) || !Policies.TryGetValue(kind, out policy))
            {
                return GroguDb.Error(400, "validation", "Unknown upload type.");
            }

            if (policy.Role != null && !User.IsInRole(policy.Role))
            {
                return GroguDb.Error(403, "forbidden", "Your account can't upload this kind of file.");
            }

            if (file == null || file.Length == 0)
            {
                return GroguDb.Error(400, "validation", "Choose a file to upload.");
            }

            using (var stream = file.OpenReadStream())
            {
                var header = new byte[16];
                var read = await stream.ReadAsync(header, 0, header.Length);

                string extension, fileKind;
                if (!TryDetect(header, read, out extension, out fileKind))
                {
                    return GroguDb.Error(400, "validation",
                        "That file type isn't supported. Use PNG, JPEG or WebP images, or MP4 or WebM video.");
                }

                var limit = fileKind == "video" ? policy.VideoLimit : policy.ImageLimit;
                if (limit == 0)
                {
                    return GroguDb.Error(400, "validation", "Videos can't be used here. Choose an image.");
                }
                if (file.Length > limit)
                {
                    return GroguDb.Error(400, "validation",
                        "That file is too large. The limit is " + (limit / MB) + " MB.");
                }

                stream.Position = 0;
                var url = await _files.SaveAsync(stream, extension);

                return Ok(new
                {
                    url,
                    kind = fileKind,
                    name = DisplayName(file.FileName),
                    size = file.Length
                });
            }
        }

        /// <summary>Identifies PNG, JPEG, WebP, MP4 and WebM from their leading bytes.</summary>
        private static bool TryDetect(byte[] h, int n, out string extension, out string kind)
        {
            extension = null;
            kind = null;

            if (n >= 8 && h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47)
            {
                extension = ".png"; kind = "image";
            }
            else if (n >= 3 && h[0] == 0xFF && h[1] == 0xD8 && h[2] == 0xFF)
            {
                extension = ".jpg"; kind = "image";
            }
            else if (n >= 12 && h[0] == 'R' && h[1] == 'I' && h[2] == 'F' && h[3] == 'F'
                     && h[8] == 'W' && h[9] == 'E' && h[10] == 'B' && h[11] == 'P')
            {
                extension = ".webp"; kind = "image";
            }
            else if (n >= 12 && h[4] == 'f' && h[5] == 't' && h[6] == 'y' && h[7] == 'p')
            {
                extension = ".mp4"; kind = "video";
            }
            else if (n >= 4 && h[0] == 0x1A && h[1] == 0x45 && h[2] == 0xDF && h[3] == 0xA3)
            {
                extension = ".webm"; kind = "video";
            }

            return extension != null;
        }

        /// <summary>
        /// The uploader's file name, for display only: path parts and control
        /// characters are dropped and the length is capped. It is never used to
        /// build a path.
        /// </summary>
        private static string DisplayName(string fileName)
        {
            var name = Path.GetFileName(fileName ?? string.Empty);
            var clean = new string(name.Where(c => !char.IsControl(c)).ToArray());
            return clean.Length > 120 ? clean.Substring(0, 120) : clean;
        }
    }
}
