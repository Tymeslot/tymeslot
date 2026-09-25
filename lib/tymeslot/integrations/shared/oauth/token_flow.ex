defmodule Tymeslot.Integrations.Shared.OAuth.TokenFlow do
  @moduledoc """
  Shared helpers for performing OAuth token exchanges and refreshes.

  Failures are logged here rather than at each call site, on the same terms as
  `Tymeslot.Integrations.Common.OAuth.TokenExchange`: the status and a redacted
  body, plus whatever `:log_context` the caller supplies. This is the live
  Outlook calendar refresh path, so a line without the integration behind it is
  a failure nobody can attribute.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Common.OAuth.LogContext

  require Logger

  @default_headers [{"Content-Type", "application/x-www-form-urlencoded"}]

  # One pair per operation. Kept as literals rather than interpolated, so each
  # failure stays a constant message the log pipeline can group and alert on.
  @failure_messages %{
    exchange: %{
      http: "OAuth token exchange failed",
      network: "Network error during token exchange"
    },
    refresh: %{
      http: "OAuth token refresh failed",
      network: "Network error during token refresh"
    }
  }

  @type token_error ::
          {:http_error, integer(), String.t()}
          | {:network_error, any()}

  @doc """
  Exchanges an authorization code for tokens.

  Takes the same `:log_context` as `refresh_token/3`.
  """
  @spec exchange_code(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, token_error()}
  def exchange_code(token_url, params, opts) do
    request_tokens(token_url, params, opts, :exchange)
  end

  @doc """
  Refreshes an access token.

  ## Options

    * `:log_context` — key/value pairs merged into the failure log lines so a
      failure can be attributed to an integration without joining against
      neighbouring lines. Only `:integration_id`, `:user_id` and `:provider`
      are kept; anything else is dropped. Pass ids, never the integration
      struct: it carries the OAuth credentials this module has just decrypted,
      and the response body is redacted here for the same reason.
  """
  @spec refresh_token(String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, token_error()}
  def refresh_token(token_url, params, opts) do
    request_tokens(token_url, params, opts, :refresh)
  end

  defp request_tokens(token_url, params, opts, operation) do
    headers = Keyword.get(opts, :headers, @default_headers)
    log_context = LogContext.from_opts(opts)
    messages = @failure_messages[operation]

    case Config.http_client_module().request(
           :post,
           token_url,
           URI.encode_query(params),
           headers,
           []
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, Jason.decode!(body)}

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          messages.http,
          log_context ++ [status: status, body: Redactor.redact_and_truncate(body)]
        )

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error(
          messages.network,
          log_context ++ [reason: inspect(reason)]
        )

        {:error, {:network_error, reason}}
    end
  end
end
