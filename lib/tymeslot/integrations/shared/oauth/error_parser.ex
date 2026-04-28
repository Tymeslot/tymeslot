defmodule Tymeslot.Integrations.Common.OAuth.ErrorParser do
  @moduledoc """
  Shared OAuth error-message builder used by all provider OAuth helpers.

  Extracts the OAuth `error` field from token-endpoint HTTP error bodies and
  formats it as a human-readable reason string.  The status guard ensures that
  only **400** and **401** responses are inspected for an OAuth-protocol error
  code — these are the only statuses token endpoints use for protocol-level
  failures.  All other statuses (5xx server errors, unexpected 4xx codes, etc.)
  fall back to a generic message that does *not* match any permanent-auth
  marker in `ResponseHandler`, so transient infrastructure errors are never
  misclassified as permanent auth failures.
  """

  @oauth_error_statuses [400, 401]

  @doc """
  Builds a human-readable error message from an HTTP error response.

  For 400/401 responses whose body contains a JSON `{"error": "..."}` field,
  the OAuth error code is embedded directly in the message so that
  `ResponseHandler.permanent_auth_error?/1` can recognise permanent failures
  (e.g. `invalid_grant`, `invalid_client`, `access_denied`).

  For all other statuses, or when the body does not contain an OAuth error
  code, a generic message is returned that will *not* trigger the
  permanent-auth fast-path.

  ## Examples

      iex> ErrorParser.build_message("Token refresh failed", 400, ~s({"error":"invalid_grant"}))
      "Token refresh failed: invalid_grant"

      iex> ErrorParser.build_message("Token refresh failed", 503, ~s({"error":"access_denied"}))
      "Token refresh failed: HTTP 503 (see logs for details)"

      iex> ErrorParser.build_message("Token refresh failed", 400, "Bad Request")
      "Token refresh failed: HTTP 400 (see logs for details)"
  """
  @spec build_message(String.t(), integer(), term()) :: String.t()
  def build_message(prefix, status, body) when status in @oauth_error_statuses do
    case parse_oauth_error_type(body) do
      nil -> "#{prefix}: HTTP #{status} (see logs for details)"
      error_type -> "#{prefix}: #{error_type}"
    end
  end

  def build_message(prefix, status, _body) do
    "#{prefix}: HTTP #{status} (see logs for details)"
  end

  # Returns the value of the `"error"` key from a JSON body, or nil.
  # Non-binary bodies and non-JSON binaries both return nil — defensive
  # against unexpected response shapes without raising.
  @spec parse_oauth_error_type(term()) :: String.t() | nil
  defp parse_oauth_error_type(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) -> error
      _other -> nil
    end
  end

  defp parse_oauth_error_type(_body), do: nil
end
