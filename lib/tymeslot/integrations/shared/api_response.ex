defmodule Tymeslot.Integrations.Shared.ApiResponse do
  @moduledoc """
  Shared HTTP response handling for the JSON provider API clients.

  Every provider returns its own error vocabulary, but the envelope around it
  is the same: decode a JSON body on success, pass a transport failure through,
  and fall back to a redacted log line plus an opaque message for any status
  the provider does not model.

  Centralising that envelope is a safety property rather than a tidiness one.
  The generic fallback is the only place a raw provider body is logged, so it
  is the only place redaction can be forgotten. A provider that handles its own
  statuses inline would have to remember `Redactor.redact_and_truncate/1` every
  time; routing through here means it cannot be skipped.

  Two result contracts share that fallback:

    * `handle/2` and `handle/3`, for the calendar clients (Google Calendar,
      Microsoft Graph), return `{:error, reason, message}`.
    * `handle_tagged/2`, for the video providers, returns
      `{:error, {:http_error, status, message}}` for an unmodelled status and
      the transport reason untouched, the shapes `BreakerOutcome` and the
      video callers already branch on.

  For the calendar contract, throttling and server failure are classified
  here too, because both providers answer them alike: a 429 is
  `:rate_limited`, carrying the `Retry-After` seconds as `"retry_after:<n>"`
  when the header gives them, and a 5xx is `:server_error`. Both are
  transient; neither is a network failure, and a caller that waits out a rate
  limit needs to tell them apart.

  Any other 4xx (400, 409, 412, 422, ...) is `:refused`: the provider
  understood the request and declined it, so sending it again changes
  nothing, and that holds for a 403 whose body will not decode too. A success
  body that will not decode is `:malformed_response`, which, like a 5xx, is
  transient. `:network_error` is kept for a request that never got an answer.

  Providers keep what genuinely differs, passing it as `:custom`: Google
  classifies a 403 from `error.errors[].reason`, Graph from `error.code` plus a
  `Retry-After` header, and a video provider whose 401 means a revoked grant
  flags the integration on the result it gets back.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Retry
  alias Tymeslot.Integrations.Calendar.HTTP
  alias Tymeslot.Integrations.Shared.OAuth.ErrorParser
  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint

  import ErrorParser, only: [is_oauth_error_status: 1]

  @typedoc """
  The three-element error shape both calendar API clients return: a machine
  readable reason alongside a message safe to surface to the caller.
  """
  @type result :: {:ok, map()} | {:error, atom(), String.t()}

  @typedoc """
  The video providers' shape: an unmodelled status keeps its number, so
  `BreakerOutcome` can tell an outage (5xx, 429, 408) from a refusal, and a
  transport failure is passed through as the reason the client gave.
  """
  @type tagged_result ::
          {:ok, map()}
          | {:error, {:http_error, integer(), String.t()}}
          | {:error, :malformed_response}
          | {:error, term()}

  # Long enough for a provider's one-line explanation, short enough that an
  # echoed request cannot fill the returned reason.
  @detail_max_bytes 512

  @doc """
  Handles a response whose 404 should name the missing resource.

  A bare 404 means "calendar" on a calendar-scoped path and "event" on an
  event-scoped one; only the request path, which the caller has in scope, can
  tell them apart.
  """
  @spec handle(term(), String.t(), keyword()) :: result()
  def handle(response, path, opts) do
    case handle(response, opts) do
      {:error, :not_found, _generic} -> {:error, :not_found, HTTP.not_found_message(path)}
      result -> result
    end
  end

  @doc """
  Handles a response, giving the provider first refusal on the status.

  ## Options

    * `:label` — provider name used in the fallback log line, e.g.
      `"Google Calendar"`. **Required.**
    * `:custom` — a `(response -> result | :default)` consulted before the
      shared clauses. Returning `:default` accepts the shared handling.
  """
  @spec handle(term(), keyword()) :: result()
  def handle(response, opts) do
    label = Keyword.fetch!(opts, :label)
    custom = Keyword.get(opts, :custom, fn _response -> :default end)

    case custom.(response) do
      :default -> default_handle(response, label)
      result -> result
    end
  end

  @doc """
  Handles a response for a client whose errors are
  `{:error, {:http_error, status, message}}`.

  A success status decodes its JSON body (`:malformed_response` when it will
  not decode), a transport failure is returned as it came, and any other
  status is logged once, redacted, and returned with its status.

  ## Options

    * `:label` — provider name for the log line and the message, e.g.
      `"Zoom"`. **Required.**
    * `:custom` — a `(response -> result | :default)` consulted first, as for
      `handle/2`.
    * `:detail` — a `(decoded_error_body -> String.t() | nil)` naming the
      provider's own explanation, which the message carries redacted and
      bounded. Without one, or when the body does not decode, the message
      points at the logs instead.
    * `:success` — the statuses that count as success. Default `200..299`.
    * `:log_level` — level of the fallback log line. Default `:error`; a
      best-effort call whose failure changes nothing passes `:warning`.
  """
  @spec handle_tagged(term(), keyword()) :: tagged_result() | term()
  def handle_tagged(response, opts) do
    custom = Keyword.get(opts, :custom, fn _response -> :default end)

    case custom.(response) do
      :default -> tagged_default(response, opts)
      result -> result
    end
  end

  defp tagged_default({:ok, %{status: status, body: body}} = response, opts) do
    if status in Keyword.get(opts, :success, 200..299),
      do: decode_tagged(body),
      else: tagged_error(response, opts)
  end

  defp tagged_default({:error, reason}, _opts), do: {:error, reason}

  defp tagged_error({:ok, %{status: status, body: body}}, opts) do
    label = Keyword.fetch!(opts, :label)
    log_unmodelled(Keyword.get(opts, :log_level, :error), label, status, body)

    detail =
      case {Keyword.get(opts, :detail), decode_tagged(body)} do
        {detail_fun, {:ok, decoded}} when is_function(detail_fun, 1) -> detail_fun.(decoded)
        _no_detail -> nil
      end

    {:error, {:http_error, status, tagged_message(label, status, detail)}}
  end

  defp tagged_message(label, status, detail) when is_binary(detail) and detail != "",
    do:
      "#{label} API error (#{status}): #{Redactor.redact_and_truncate(detail, @detail_max_bytes)}"

  defp tagged_message(label, status, _detail),
    do: "#{label} API error (#{status}): see logs for details"

  defp decode_tagged(body) when is_map(body), do: {:ok, body}
  defp decode_tagged(body) when not is_binary(body), do: {:error, :malformed_response}

  defp decode_tagged(body) do
    case decode_body(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, :malformed_response, _message} -> {:error, :malformed_response}
    end
  end

  @doc """
  A `:custom` for `handle_tagged/2` that reports a 429 as
  `{:error, {:rate_limited, seconds}}`, the form `Retry.with_backoff/2` waits
  out, with the `Retry-After` seconds when the provider names them.
  """
  @spec rate_limited(term()) :: {:error, {:rate_limited, non_neg_integer() | nil}} | :default
  def rate_limited({:ok, %{status: 429} = response}),
    do: {:error, {:rate_limited, Retry.retry_after_seconds(response)}}

  def rate_limited(_response), do: :default

  @doc """
  Decodes a provider error body and hands its `error` object to `fun`.

  Both providers nest the human-readable text at `error.message` and their
  classification hints as siblings of it, so the decode-and-reach step is
  shared while the classification stays with the provider. A body that will not
  decode cannot be classified, so it short-circuits to `:refused`: the status
  is still a 4xx, a statement about the request rather than the provider's
  health, and an unreadable 403 counted as `:malformed_response` would let
  one account's refusal open the breaker every account shares.
  """
  @spec with_error_object(binary(), (String.t(), map() -> {:error, atom(), String.t()})) ::
          {:error, atom(), String.t()}
  def with_error_object(body, fun) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        fun.(get_in(decoded, ["error", "message"]) || "Forbidden", decoded)

      {:error, _reason} ->
        {:error, :refused, "Forbidden (malformed response)"}
    end
  end

  @doc """
  Maps a token endpoint refresh onto the calendar clients' refresh result.

  A 400 or 401 is the provider refusing the credential, and its message keeps
  the OAuth error code so the refresh job and the health check can tell a
  revoked grant (`invalid_grant`) from other refusals. Anything else, a 200
  that did not decode included, is transient, and missing client credentials
  are an authentication error.
  """
  @spec token_refresh({:ok, TokenEndpoint.tokens()} | {:error, TokenEndpoint.refresh_error()}) ::
          {:ok, {String.t(), String.t(), DateTime.t()}} | {:error, atom(), String.t()}
  def token_refresh(
        {:ok, %{access_token: access, refresh_token: refresh, expires_at: expires_at}}
      ),
      do: {:ok, {access, refresh, expires_at}}

  def token_refresh({:error, {:http_error, status, body}}) when is_oauth_error_status(status),
    do: {:error, :unauthorized, ErrorParser.build_message("Token refresh failed", status, body)}

  def token_refresh({:error, {:http_error, status, _body}}),
    do: {:error, :network_error, "HTTP #{status}"}

  def token_refresh({:error, {:network_error, reason}}),
    do: {:error, :network_error, "Network error: #{inspect(reason)}"}

  def token_refresh({:error, {:not_configured, message}}),
    do: {:error, :authentication_error, message}

  defp default_handle({:ok, %{status: status, body: body}}, _label)
       when status in [200, 201, 204] do
    decode_body(body)
  end

  defp default_handle({:ok, %{status: 401}}, _label) do
    {:error, :unauthorized, "Token expired or invalid"}
  end

  defp default_handle({:ok, %{status: 404}}, _label) do
    {:error, :not_found, "Calendar not found"}
  end

  defp default_handle({:ok, %{status: 429} = response}, _label) do
    {:error, :rate_limited, rate_limited_message(response, "Too many requests")}
  end

  defp default_handle({:ok, %{status: status, body: body}}, label) when status in 500..599 do
    log_unmodelled(:warning, label, status, body)
    {:error, :server_error, "HTTP #{status}"}
  end

  # The caller gets an opaque message: the detail is in the logs, where it is
  # truncated and stripped of credentials.
  defp default_handle({:ok, %{status: status, body: body}}, label) do
    log_unmodelled(:error, label, status, body)
    {:error, unrecognised_status_reason(status), "HTTP #{status} (see logs for details)"}
  end

  defp default_handle({:error, reason}, _label) do
    {:error, :network_error, "Network error: #{inspect(reason)}"}
  end

  @doc """
  The message a rate-limited `response` carries: `"retry_after:<n>"` when its
  `Retry-After` header gives a number of seconds (the form
  `Tymeslot.Workers.RetryHelpers.parse_retry_after_from_message/1` reads),
  `fallback` otherwise.
  """
  @spec rate_limited_message(map(), String.t()) :: String.t()
  def rate_limited_message(response, fallback) do
    case Retry.retry_after_seconds(response) do
      seconds when is_integer(seconds) -> "retry_after:" <> Integer.to_string(seconds)
      nil -> fallback
    end
  end

  # A 408 is the server giving up on waiting for the request, which a resend
  # may well get through; every other 4xx here is a refusal of the request
  # itself. Anything outside 4xx that no clause above recognised (a stray 3xx)
  # says nothing about the request, so it stays a transport failure.
  defp unrecognised_status_reason(408), do: :timeout
  defp unrecognised_status_reason(status) when status in 400..499, do: :refused
  defp unrecognised_status_reason(_status), do: :network_error

  # The only place an unrecognised provider body is logged, and so the only
  # one that has to redact.
  defp log_unmodelled(level, label, status, body) do
    Logger.log(level, "Provider API error",
      provider: label,
      status: status,
      body: Redactor.redact_and_truncate(body)
    )
  end

  defp decode_body(""), do: {:ok, %{}}

  defp decode_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :malformed_response, "Malformed JSON response"}
    end
  end
end
