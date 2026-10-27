defmodule Tymeslot.Integrations.Video.Providers.OAuthRoom do
  @moduledoc """
  What the OAuth video providers (Zoom, Microsoft Teams, Google Meet) share:
  creating a room in its two circuit-breaker phases, telling a refused grant
  from an outage, and keeping the integration's access token valid.

  A provider describes itself with a `t:spec/0` and keeps only what is its
  own: its API calls, its scope rules and which of its refresh failures are
  fatal.

  ## The token

  `ensure_valid_token/3` answers with the provider config carrying a usable
  access token. A token that is not good for long enough is refreshed with
  `Tymeslot.Integrations.Shared.OAuth.Refresh`, the locked, double-checked
  refresh calendar integrations share: under a lock on the integration it
  re-reads the row, uses its token when a sibling has refreshed it already,
  and otherwise refreshes with the credentials it just read (Zoom and
  Microsoft rotate refresh tokens, so a caller's older copy may hold one the
  provider has retired) and writes the result before releasing the lock.

  What a refresh writes is the same for every provider: the new access token
  and expiry, and the refresh token and scope only when the provider returned
  them, so an omitted one never clears the stored one.
  """

  require Logger

  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Shared.OAuth.Refresh
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @type config :: map()

  @typedoc """
  A provider's OAuth facts.

    * `:helper` — its OAuth helper, exposing `refresh_access_token/3`.
    * `:label` — its name in log lines.
    * `:validate_token` — whether `config`'s token is good as it is:
      `{:ok, :valid}`, `{:ok, :needs_refresh}`, or `{:error, reason}`.
    * `:scope` — the scope to ask a refresh for, given the config (`nil`
      lets the helper use its default).
    * `:persist_failure` — `:fatal` for a provider that rotates its refresh
      token on every refresh (Zoom), where a token that could not be written
      is one the provider has already invalidated; `:best_effort` otherwise,
      as the stored credentials are still good.
  """
  @type spec :: %{
          helper: module(),
          label: String.t(),
          validate_token: (config() -> {:ok, :valid | :needs_refresh} | {:error, term()}),
          scope: (config() -> String.t() | nil),
          persist_failure: :fatal | :best_effort
        }

  @doc """
  Creates a room in the two phases `ProviderAdapter` puts either side of the
  circuit breaker, for a caller that calls the provider directly: the
  provider's `precheck_create_meeting_room/1`, then its
  `finish_create_meeting_room/2`.
  """
  @spec create_meeting_room(module(), config(), String.t()) :: {:ok, term()} | {:error, term()}
  def create_meeting_room(provider, config, label) do
    case provider.precheck_create_meeting_room(config) do
      {:ok, token} ->
        provider.finish_create_meeting_room(token, config)

      {:provider_error, reason} ->
        log_create_failure(label, reason)
        {:error, reason}

      {:error, reason} = error ->
        log_create_failure(label, reason)
        error
    end
  end

  @doc """
  Sorts a token result for the circuit breaker. A refused grant
  (`invalid_grant`, `invalid_client`, `access_denied`) is the tenant's
  credential, not the provider's availability, and stays `{:error, _}`, out
  of the breaker's reach (`BreakerOutcome.permanent_credential_error?/1`
  shares the rule with the health check's reauth fast-path). Anything else, a
  network error or an unrecognised status, is `{:provider_error, _}` for the
  breaker to witness.
  """
  @spec classify_token_result({:ok, term()} | {:error, term()}) ::
          {:ok, term()} | {:error, term()} | {:provider_error, term()}
  def classify_token_result({:ok, _token} = ok), do: ok

  def classify_token_result({:error, reason} = error) do
    if BreakerOutcome.permanent_credential_error?(reason),
      do: error,
      else: {:provider_error, reason}
  end

  @doc """
  Returns `config` carrying a usable access token, refreshed first when the
  spec's `:validate_token` says so (see the moduledoc).

  ## Options

    * `:refused_token` — the access token the provider has just answered
      with a 401. It was refused server-side, so the stored expiry cannot be
      trusted: the token is refreshed whatever it says, still under the lock,
      unless a sibling has already replaced the refused token with another.
      The comparison is with the refused token itself, not the config's: an
      operation may have refreshed at its start, so the token that drew the
      401 can be newer than the one it was given.
  """
  @spec ensure_valid_token(config(), spec(), keyword()) :: {:ok, config()} | {:error, term()}
  def ensure_valid_token(config, spec, opts \\ []) do
    case Keyword.fetch(opts, :refused_token) do
      {:ok, refused_token} -> refresh(config, spec, {:refused, refused_token})
      :error -> check_then_refresh(config, spec)
    end
  end

  defp check_then_refresh(config, spec) do
    case spec.validate_token.(config) do
      {:ok, :valid} ->
        {:ok, config}

      {:ok, :needs_refresh} ->
        refresh(config, spec, :expiry)

      {:error, reason} ->
        Logger.error("Video OAuth token validation failed",
          provider: spec.label,
          reason: LogFormat.reason(reason)
        )

        {:error, "Token validation failed: #{reason}"}
    end
  end

  # A config without its integration and user is a transient one (a
  # connection probe) with no row to coordinate on or write back to.
  defp refresh(config, spec, why) do
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)

    if is_nil(integration_id) or is_nil(user_id) do
      with {:ok, tokens} <- request_refresh(config, spec) do
        {:ok, with_tokens(config, tokens)}
      end
    else
      Refresh.run(Refresh.lock_key(:video, integration_id), %{
        fetch: fn -> {:ok, fetch_current(integration_id, user_id)} end,
        valid?: &still_good?(&1, why),
        already_valid: fn {:found, _integration, decrypted} ->
          {:ok, with_stored_tokens(config, decrypted)}
        end,
        refresh: &request_refresh(refresh_config(&1, config), spec),
        persist: fn current, tokens -> persist(current, config, tokens, spec) end
      })
    end
  end

  defp fetch_current(integration_id, user_id) do
    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, integration} ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(integration)
        {:found, integration, Map.put(decrypted, :oauth_scope, integration.oauth_scope)}

      {:error, :not_found} ->
        :missing
    end
  end

  # After a 401 the refused token's expiry cannot be trusted. Only a sibling
  # having replaced it already (the stored token differs from the refused one)
  # makes a refresh unnecessary.
  defp still_good?(:missing, _why), do: false

  defp still_good?({:found, _integration, decrypted}, {:refused, refused_token}),
    do: decrypted.access_token != refused_token

  defp still_good?({:found, _integration, decrypted}, :expiry),
    do: Refresh.valid?(decrypted.token_expires_at)

  # The refresh spends the credentials just read under the lock, never the
  # caller's copy.
  defp refresh_config(:missing, config), do: config

  defp refresh_config({:found, _integration, decrypted}, config),
    do: with_stored_tokens(config, decrypted)

  defp request_refresh(config, spec) do
    case spec.helper.refresh_access_token(
           Map.get(config, :refresh_token),
           spec.scope.(config),
           log_context: [
             integration_id: Map.get(config, :integration_id),
             user_id: Map.get(config, :user_id)
           ]
         ) do
      {:ok, tokens} ->
        Logger.info("Refreshed video OAuth token", provider: spec.label)
        {:ok, tokens}

      {:error, reason} ->
        Logger.error("Failed to refresh video OAuth token",
          provider: spec.label,
          reason: LogFormat.reason(reason)
        )

        # The helper words the reason ("Token refresh failed: invalid_grant").
        {:error, reason}
    end
  end

  defp persist(:missing, config, tokens, spec) do
    Logger.warning("Video integration vanished before token update",
      provider: spec.label,
      integration_id: Map.get(config, :integration_id)
    )

    {:ok, with_tokens(config, tokens)}
  end

  defp persist({:found, integration, _decrypted}, config, tokens, spec) do
    case VideoIntegrationQueries.update(integration, token_attrs(tokens)) do
      {:ok, _updated} ->
        {:ok, with_tokens(config, tokens)}

      {:error, reason} ->
        Logger.error("Failed to persist video OAuth tokens",
          provider: spec.label,
          integration_id: integration.id,
          reason: LogFormat.reason(reason)
        )

        persist_failed(spec.persist_failure, config, tokens)
    end
  end

  defp persist_failed(:fatal, _config, _tokens), do: {:error, :token_persist_failed}
  defp persist_failed(:best_effort, config, tokens), do: {:ok, with_tokens(config, tokens)}

  defp token_attrs(tokens) do
    %{access_token: tokens.access_token, token_expires_at: tokens.expires_at}
    |> put_present(:refresh_token, tokens.refresh_token)
    |> put_present(:oauth_scope, tokens[:scope])
  end

  defp with_tokens(config, tokens), do: Map.merge(config, token_attrs(tokens))

  defp with_stored_tokens(config, decrypted) do
    Map.merge(
      config,
      Map.take(decrypted, [:access_token, :refresh_token, :token_expires_at, :oauth_scope])
    )
  end

  defp put_present(attrs, key, value) when is_binary(value) and value != "",
    do: Map.put(attrs, key, value)

  defp put_present(attrs, _key, _value), do: attrs

  defp log_create_failure(label, reason) do
    Logger.error("Failed to create video room", provider: label, error: LogFormat.reason(reason))
  end
end
