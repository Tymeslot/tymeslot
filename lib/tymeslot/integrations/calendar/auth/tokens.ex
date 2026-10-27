defmodule Tymeslot.Integrations.Calendar.Tokens do
  @moduledoc """
  The one entry point for a calendar integration's OAuth access token
  (Google and Outlook).

  Every path that needs a usable token goes through here: each provider API
  call (`with_access_token/4`), and the scheduled refresh job and other
  forced refreshes (`refresh_oauth_token/2`). Both run the shared locked flow
  in `Tymeslot.Integrations.Shared.OAuth.Refresh` on one key per integration,
  and both persist through the same function, so neither can refresh a token
  the other is refreshing, and both clear a stale `sync_error` the same way.
  """

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Shared.OAuth.Refresh

  require Logger

  @type integration :: CalendarIntegrationSchema.t()

  @typedoc """
  A provider's refresh: the calendar API module's `refresh_token/1`.
  """
  @type refresh_fun :: (integration() ->
                          {:ok, {String.t(), String.t() | nil, DateTime.t()}}
                          | {:error, term()}
                          | {:error, atom(), String.t()})

  @providers ["google", "outlook"]

  # How long before expiry a provider API call refreshes the token.
  @buffer_seconds 300

  @doc """
  Runs `callback` with a usable access token for the integration, refreshing
  it first when it expires within the buffer.

  `refresh_fun` is the calling API module's own `refresh_token/1`. A refresh
  failure is returned as it is, so a provider's `{:error, type, message}`
  reaches the caller unchanged.

  ## Options

    * `:buffer_seconds` — refresh a token expiring within this many seconds
      (5 minutes).
  """
  @spec with_access_token(integration(), refresh_fun(), (String.t() -> result), keyword()) ::
          result | {:error, term()} | {:error, atom(), String.t()}
        when result: var
  def with_access_token(
        %CalendarIntegrationSchema{} = integration,
        refresh_fun,
        callback,
        opts \\ []
      ) do
    buffer_seconds = Keyword.get(opts, :buffer_seconds, @buffer_seconds)

    result =
      if Refresh.valid?(integration.token_expires_at, buffer_seconds) do
        {:ok, CalendarIntegrationSchema.decrypt_oauth_tokens(integration)}
      else
        refresh(integration, refresh_fun, &Refresh.valid?(&1.token_expires_at, buffer_seconds))
      end

    with {:ok, %{access_token: access_token}} <- result do
      callback.(access_token)
    end
  end

  @doc """
  Refreshes the integration's token unless the row, re-read under the lock,
  already holds one valid for longer than the buffer, and returns the
  integration with its tokens decrypted.

  The refresh job passes its own scheduling window as the buffer, so it
  refreshes ahead of expiry. A row whose expiry has moved past the one on
  `integration` was refreshed by someone else since the caller read it, and
  is not refreshed again while it is good for the usual 5 minutes: a Google
  token lives an hour, inside the job's window, so the buffer alone would
  have the job refresh a token an API call refreshed a moment earlier.

  A failure is `{:error, reason}`, with a provider's typed failure as
  `{:error, {type, message}}`. When the stored credentials no longer
  decrypt, the integration is flagged for reconnection and the answer is
  `{:error, :requires_reencryption}`, or `{:error, :reauth_flag_failed}` when
  the flag could not be recorded. When they do not decrypt because their key
  is missing from the keyring, the answer is the same
  `{:error, :requires_reencryption}`, but nothing is flagged: the operator is
  alerted instead (`Tymeslot.Integrations.Shared.ReauthHandling.flag/3`). An integration deleted before the re-read
  is `{:error, :integration_not_found}`, distinct from an event's
  `:not_found`. A wait for another holder of the lock that outlasts the lock
  timeout is `{:error, :lock_timeout}`.

  ## Options

    * `:buffer_seconds` — refresh a token expiring within this many seconds
      (5 minutes).
    * `:lock_timeout` — how long to wait for another refresh's lock, in
      milliseconds (`Tymeslot.Integrations.Shared.OAuth.Refresh.run/3`).
  """
  @spec refresh_oauth_token(integration(), keyword()) :: {:ok, integration()} | {:error, term()}
  def refresh_oauth_token(integration, opts \\ [])

  def refresh_oauth_token(%CalendarIntegrationSchema{provider: provider} = integration, opts)
      when provider in @providers do
    buffer_seconds = Keyword.get(opts, :buffer_seconds, @buffer_seconds)

    valid? = fn current ->
      Refresh.valid?(current.token_expires_at, buffer_seconds) or
        (refreshed_since?(current, integration) and Refresh.valid?(current.token_expires_at))
    end

    case refresh(integration, &provider_refresh/1, valid?, Keyword.take(opts, [:lock_timeout])) do
      {:error, type, message} -> {:error, {type, message}}
      result -> result
    end
  end

  def refresh_oauth_token(_integration, _opts), do: {:error, :unsupported_provider}

  @doc """
  The lock every refresh of a calendar integration's OAuth token takes.
  """
  @spec refresh_lock_key(term()) :: Refresh.lock_key()
  def refresh_lock_key(integration_id), do: Refresh.lock_key(:calendar, integration_id)

  defp refresh(integration, refresh_fun, valid?, opts \\ []) do
    Refresh.run(
      refresh_lock_key(integration.id),
      %{
        fetch: fn -> fetch(integration.id) end,
        valid?: valid?,
        already_valid: &{:ok, CalendarIntegrationSchema.decrypt_oauth_tokens(&1)},
        # From the row just read, not the caller's copy: a long job's copy can
        # predate a reconnect flag, and the attributes written depend on it.
        refresh: refresh_fun,
        persist: &persist/2
      },
      opts
    )
  end

  defp refreshed_since?(%{token_expires_at: nil}, _seen), do: false
  defp refreshed_since?(_current, %{token_expires_at: nil}), do: true

  defp refreshed_since?(current, seen),
    do: DateTime.compare(current.token_expires_at, seen.token_expires_at) == :gt

  defp fetch(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} -> {:ok, integration}
      {:error, :requires_reencryption, stale} -> flag_unreadable(stale)
      {:error, :not_found} -> {:error, :integration_not_found}
    end
  end

  # `handle_reauth_required/1` answers in Oban's terms; this module's callers
  # expect `{:ok, _} | {:error, _}`.
  defp flag_unreadable(stale) do
    case Management.handle_reauth_required(stale) do
      {:discard, _reason} -> {:error, :requires_reencryption}
      {:error, _reason} -> {:error, :reauth_flag_failed}
    end
  end

  defp provider_refresh(%{provider: "google"} = integration),
    do: Config.google_calendar_api_module().refresh_token(integration)

  defp provider_refresh(%{provider: "outlook"} = integration),
    do: Config.outlook_calendar_api_module().refresh_token(integration)

  # A failed write is surfaced rather than answered with the fresh token:
  # the row would still hold the old one, so every later caller would refresh
  # again, risking the provider's rate limit and, with Google's one-use
  # refresh tokens, revocation.
  defp persist(integration, {access_token, refresh_token, expires_at}) do
    attrs = refreshed_token_attrs(integration, access_token, refresh_token, expires_at)

    case CalendarIntegrationQueries.update(integration, attrs) do
      {:ok, updated} ->
        {:ok, CalendarIntegrationSchema.decrypt_oauth_tokens(updated)}

      {:error, changeset} ->
        Logger.error("Failed to persist refreshed OAuth tokens",
          integration_id: integration.id,
          error: LogFormat.reason(changeset.errors)
        )

        {:error, :token_persist_failed}
    end
  end

  # A successful refresh only means the token is valid again; it says nothing
  # about whatever flagged the integration for reauth in the first place (a
  # deleted booking calendar, no calendar selected). Clearing `sync_error`
  # here while `needs_reauth` is still true would erase the reason the
  # dashboard notice and reauth email depend on.
  defp refreshed_token_attrs(integration, access_token, refresh_token, expires_at) do
    maybe_clear_sync_error(
      %{access_token: access_token, refresh_token: refresh_token, token_expires_at: expires_at},
      integration
    )
  end

  defp maybe_clear_sync_error(attrs, %{needs_reauth: true}), do: attrs
  defp maybe_clear_sync_error(attrs, _integration), do: Map.put(attrs, :sync_error, nil)
end
