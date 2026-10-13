using System;
using System.Data;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Npgsql;
using NpgsqlTypes;

namespace Grogu.Infrastructure
{
    /// <summary>
    /// Runs the <c>grogu_*</c> stored functions that back <c>/api/v1</c> and hands
    /// their jsonb result straight to the client.
    ///
    /// The functions already return documents shaped like the frontend's types, so
    /// nothing here re-serialises them: the string Postgres produced is written to
    /// the response as-is. That keeps the contract defined in exactly one place —
    /// the SQL — instead of being restated in C# DTOs that could drift from it.
    /// </summary>
    public class GroguDb
    {
        private readonly string _connectionString;

        public GroguDb(IConfiguration configuration)
        {
            _connectionString = configuration.GetConnectionString("NeonDBConnection");

            if (string.IsNullOrWhiteSpace(_connectionString))
            {
                throw new InvalidOperationException(
                    "No database connection string configured. Set the environment variable " +
                    "ConnectionStrings__NeonDBConnection (see README).");
            }
        }

        /// <summary>A jsonb-returning function call, as an already-serialised JSON body.</summary>
        public async Task<IActionResult> JsonAsync(string sql, params NpgsqlParameter[] parameters)
        {
            var result = await QueryJsonAsync(sql, parameters);

            if (result.Error != null)
            {
                return result.Error;
            }

            return new ContentResult
            {
                Content = result.Json,
                ContentType = "application/json",
                StatusCode = 200
            };
        }

        /// <summary>
        /// The same call, but handing back the JSON text so a caller can read a
        /// field out of it (the auth endpoints need the user id to sign a token).
        /// </summary>
        public async Task<(string Json, IActionResult Error)> QueryJsonAsync(
            string sql, params NpgsqlParameter[] parameters)
        {
            try
            {
                using (var connection = new NpgsqlConnection(_connectionString))
                {
                    await connection.OpenAsync();

                    using (var command = new NpgsqlCommand(sql, connection))
                    {
                        command.Parameters.AddRange(parameters);

                        var result = await command.ExecuteScalarAsync();

                        // A function that returns SQL NULL (no row matched) is a 404,
                        // not a body of "null".
                        if (result == null || result == DBNull.Value)
                        {
                            return (null, Error(404, "not-found", "Not found."));
                        }

                        return (result.ToString(), null);
                    }
                }
            }
            catch (PostgresException ex)
            {
                return (null, TranslateError(ex));
            }
        }

        /// <summary>
        /// Maps the custom SQLSTATEs raised by the stored functions onto HTTP status
        /// codes and onto the string codes the frontend's <c>ServiceError</c> branches on.
        /// </summary>
        private static IActionResult TranslateError(PostgresException ex)
        {
            switch (ex.SqlState)
            {
                case "GR001": return Error(404, "not-found", ex.MessageText);
                case "GR002": return Error(401, "invalid-credentials", ex.MessageText);
                case "GR003": return Error(409, "conflict", ex.MessageText);
                case "GR004": return Error(403, "forbidden", ex.MessageText);
                case "GR005": return Error(400, "validation", ex.MessageText);

                // Constraint violations that escaped an explicit check still read as
                // conflicts rather than surfacing as a 500.
                case "23505": return Error(409, "conflict", "That record already exists.");
                case "23503": return Error(400, "validation", "A referenced record does not exist.");
                case "23514": return Error(400, "validation", "That value is not allowed.");

                default:
                    // Never leak SQL text or connection details to the client.
                    return Error(500, "server-error", "Something went wrong. Please try again.");
            }
        }

        public static IActionResult Error(int status, string code, string message)
        {
            return new ObjectResult(new { message, code }) { StatusCode = status };
        }

        public static NpgsqlParameter Int(string name, int? value)
        {
            return new NpgsqlParameter(name, NpgsqlDbType.Integer)
            {
                Value = value.HasValue ? (object)value.Value : DBNull.Value
            };
        }

        public static NpgsqlParameter Text(string name, string value)
        {
            return new NpgsqlParameter(name, NpgsqlDbType.Text)
            {
                Value = value == null ? (object)DBNull.Value : value
            };
        }

        public static NpgsqlParameter Bool(string name, bool value)
        {
            return new NpgsqlParameter(name, NpgsqlDbType.Boolean) { Value = value };
        }

        /// <summary>A request body forwarded to a function's jsonb parameter verbatim.</summary>
        public static NpgsqlParameter Json(string name, string rawJson)
        {
            return new NpgsqlParameter(name, NpgsqlDbType.Jsonb)
            {
                Value = string.IsNullOrWhiteSpace(rawJson) ? "{}" : rawJson
            };
        }
    }
}
