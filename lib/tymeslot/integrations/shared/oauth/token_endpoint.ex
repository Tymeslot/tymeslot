defmodule Tymeslot.Integrations.Shared.OAuth.TokenEndpoint do
  @moduledoc """
  The one client for OAuth token endpoints: exchanging an authorisation code
  and refreshing an access token, for every provider (Google, Microsoft, Zoom).

  Both operations POST a form, log a failure once (status, redacted body, and
  the caller's `:log_context`), and answer with the normalised token map from
  `normalise_tokens/2`. A 200 whose body is not JSON (a proxy or captive portal
  answering in HTML) is an error like any other, never a raise.

  Callers turn an error into their own vocabulary; `error_message/2` is the
  shared wording for the ones that report a string.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Shared.OAuth.ErrorParser

  require Logger

  @default_headers [{"Content-Type", "application/x-www-form-urlencoded"}]

  # Token lifetime assumed when a response omits `expires_in` or sends a
  # non-integer: an hour is what Google and Microsoft issue.
  @default_expires_in 3600

  @invalid_json "Invalid JSON response from token endpoint"
  @no_access_token "Token response without an access token"

  # The keys a caller's `:log_context` may put on a failure line. Deliberately
  # narrow: enough to attribute a failure to an integration, and nothing that
  # could carry a credential. Every caller holds decrypted OAuth credentials
  # at the moment this logs.
  @log_context_keys [:integration_id, :user_id, :provider]

  # One set per operation. Kept as literals rather than interpolated, so each
  # failure stays a constant message the log pipeline can group and alert on.
  @failure_messages %{
    exchange: %{
      http: "OAuth token exchange failed",
      network: "Network error during token exchange",
      invalid_json: "OAuth token exchange returned invalid JSON",
      no_access_token: "OAuth token exchange returned no access token"
    },
    refresh: %{
      http: "OAuth token refresh failed",
      network: "Network error during token refresh",
      invalid_json: "OAuth token refresh returned invalid JSON",
      no_access_token: "OAuth token refresh returned no access token"
    }
  }

  @type operation :: :exchange | :refresh

  @typedoc """
  A failed request. An HTTP error keeps the raw body so callers can read the
  OAuth error code (`invalid_grant`, `invalid_client`) out of it; a 200 that
  did not decode is reported as an HTTP error with status 200.
  """
  @type token_error :: {:http_error, integer(), term()} | {:network_error, term()}

  @typedoc """
  A `refresh_grant/4` failure: a failed request, or a provider whose client
  credentials are not configured.
  """
  @type refresh_error :: token_error() | {:not_configured, String.t()}

  @type tokens :: %{
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          id_token: String.t() | nil,
          expires_at: DateTime.t(),
          scope: String.t() | nil
        }

  @doc """
  Exchanges an authorisation code for tokens. `params` is the form body,
  including `grant_type` and whatever client credentials the provider expects
  there.

  ## Options

    * `:headers` — replaces the default form content-type header (Zoom sends
      its client credentials as basic auth).
    * `:log_context` — see `refresh/3`.
    * `:fallback_scope` — the scope to report when the response names none.
  """
  @spec exchange_code(String.t(), map(), keyword()) :: {:ok, tokens()} | {:error, token_error()}
  def exchange_code(token_url, params, opts \\ []),
    do: request(token_url, params, opts, :exchange)

  @doc """
  Refreshes an access token.

  ## Options

    * `:headers` — as for `exchange_code/3`.
    * `:log_context` — key/value pairs merged into the failure log lines so a
      failure can be attributed to an integration without joining against
      neighbouring lines. Only `:integration_id`, `:user_id` and `:provider`
      are kept, and nils are dropped. Pass ids, never the integration struct: it carries the OAuth
      credentials, and the response body is redacted here for the same reason.
    * `:fallback_refresh_token` — kept when the provider does not rotate the
      refresh token (Google omits it from a refresh response).
    * `:fallback_scope` — the scope to report when the response names none.
  """
  @spec refresh(String.t(), map(), keyword()) :: {:ok, tokens()} | {:error, token_error()}
  def refresh(token_url, params, opts \\ []), do: request(token_url, params, opts, :refresh)

  @doc """
  Refreshes with the standard refresh-token grant, client credentials in the
  body, against the provider `config` names (Google and Microsoft; Zoom
  authenticates with basic auth and calls `refresh/3` itself).

  `scope` is sent when given and reported when the response names none. A
  refresh token the provider does not rotate is kept.

  Takes `:log_context` as `refresh/3` does.
  """
  @spec refresh_grant(module(), String.t(), String.t() | nil, keyword()) ::
          {:ok, tokens()} | {:error, refresh_error()}
  def refresh_grant(config, refresh_token, scope, opts \\ []) do
    with {:ok, client_id} <- config.fetch_client_id(),
         {:ok, client_secret} <- config.fetch_client_secret() do
      params =
        Map.reject(
          %{
            grant_type: "refresh_token",
            refresh_token: refresh_token,
            client_id: client_id,
            client_secret: client_secret,
            scope: scope
          },
          fn {_key, value} -> is_nil(value) end
        )

      refresh(config.token_url(), params,
        fallback_refresh_token: refresh_token,
        fallback_scope: scope,
        log_context: Keyword.get(opts, :log_context, [])
      )
    else
      {:error, message} -> {:error, {:not_configured, message}}
    end
  end

  @doc """
  Maps a token endpoint response body onto the token map, stamping
  `expires_at` from `expires_in` on `Tymeslot.Clock`.

  Takes the same `:fallback_refresh_token` and `:fallback_scope` options as
  `refresh/3`.
  """
  @spec normalise_tokens(map(), keyword()) :: tokens()
  def normalise_tokens(response, opts \\ []) when is_map(response) do
    expires_in =
      case response["expires_in"] do
        seconds when is_integer(seconds) -> seconds
        _other -> @default_expires_in
      end

    %{
      access_token: present(response["access_token"]),
      refresh_token:
        present(response["refresh_token"]) || Keyword.get(opts, :fallback_refresh_token),
      id_token: response["id_token"],
      expires_at: DateTime.add(Clock.utc_now(), expires_in, :second),
      scope: present(response["scope"]) || Keyword.get(opts, :fallback_scope)
    }
  end

  @doc """
  The human-readable reason for a failed request, for callers that report a
  string. For a 400 or 401 it carries the OAuth error code, so the permanent
  credential rules (`invalid_grant`, `invalid_client`) can recognise it.
  """
  @spec error_message(operation(), refresh_error()) :: String.t()
  def error_message(:exchange, {:http_error, status, body}),
    do: ErrorParser.build_message("OAuth token exchange failed", status, body)

  def error_message(:refresh, {:http_error, status, body}),
    do: ErrorParser.build_message("Token refresh failed", status, body)

  def error_message(operation, {:network_error, reason}),
    do: "Network error during token #{operation}: #{inspect(reason)}"

  def error_message(_operation, {:not_configured, message}), do: message

  defp request(token_url, params, opts, operation) do
    headers = Keyword.get(opts, :headers, @default_headers)
    log_context = log_context(opts)
    messages = @failure_messages[operation]

    case Config.http_client_module().request(
           :post,
           token_url,
           URI.encode_query(params),
           headers,
           []
         ) do
      {:ok, %{status: 200, body: body}} ->
        decode(body, opts, log_context, messages)

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          messages.http,
          log_context ++ [status: status, body: Redactor.redact_and_truncate(body)]
        )

        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error(messages.network, log_context ++ [reason: LogFormat.reason(reason)])
        {:error, {:network_error, reason}}
    end
  end

  # A 200 without an access token is no better than a refusal: persisted, it
  # would replace a working token with nothing.
  defp decode(body, opts, log_context, messages) do
    with {:ok, response} <- decode_body(body),
         %{access_token: access_token} = tokens when is_binary(access_token) <-
           normalise_tokens(response, opts) do
      {:ok, tokens}
    else
      :error ->
        Logger.error(
          messages.invalid_json,
          log_context ++ [body: Redactor.redact_and_truncate(body)]
        )

        {:error, {:http_error, 200, @invalid_json}}

      %{access_token: nil} ->
        Logger.error(messages.no_access_token, log_context)
        {:error, {:http_error, 200, @no_access_token}}
    end
  end

  # A blank value is no value: a provider answering `"refresh_token": ""` has
  # not rotated it, and the fallback must win.
  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_value), do: nil

  # Nils are dropped so a caller holding only part of the context (a transient
  # config built for a connection probe, say) does not emit `integration_id: nil`.
  defp log_context(opts) do
    opts
    |> Keyword.get(:log_context, [])
    |> Enum.filter(fn {key, value} -> key in @log_context_keys and not is_nil(value) end)
  end

  # `HttpClient` never decodes (`decode_body: false`), so a body is a binary.
  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> :error
    end
  end

  defp decode_body(_body), do: :error
end
