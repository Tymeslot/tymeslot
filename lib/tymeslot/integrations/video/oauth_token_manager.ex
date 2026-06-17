defmodule Tymeslot.Integrations.Video.OAuthTokenManager do
  @moduledoc """
  Shared OAuth token-refresh orchestration for video providers.

  Every video provider (Zoom, Teams, Google Meet) carries the same
  double-checked, locked token-refresh state machine:

    1. If we lack an `integration_id`/`user_id`, refresh directly (no lock,
       no DB re-fetch) — there is nothing to coordinate against.
    2. Otherwise acquire a blocking per-integration lock, re-fetch the
       integration from the database, and decrypt its credentials.
    3. If the freshly-read token still has more than the buffer window of
       life left, another process already refreshed it — return that token
       without hitting the OAuth endpoint.
    4. Otherwise (token still expiring, or the integration vanished),
       perform the actual OAuth refresh.

  Providers differ only in their **return shape**, captured by callbacks.
  Zoom and Teams return a bare access-token string; Google Meet returns a
  config map merged with the refreshed credentials.

    * `:refresh` performs the OAuth call, persists, and shapes the return
      value for the in-lock refresh paths (token expiring, or integration
      vanished).
    * `:already_refreshed` builds the return value when another process
      already refreshed the token, from the freshly decrypted integration.
    * `:fallback_refresh` (optional) handles the no-`integration_id`/no-
      `user_id` path where there is nothing to lock or re-fetch against.
      Defaults to `:refresh`. Teams is the one provider whose fallback
      return shape (the full refreshed-token map) differs from its in-lock
      shape (the bare access token), so it supplies its own.

  The 300-second expiry buffer is identical across providers and lives here.
  """

  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  @buffer_seconds 300

  @type config :: map()
  @type decrypted :: map()
  @type result :: {:ok, term()} | {:error, term()}

  @typedoc """
  Provider-specific hooks plugged into the shared flow.

    * `:provider` — lock-key atom (`:zoom`, `:teams`, `:google_meet`).
    * `:refresh` — performs the OAuth refresh, persistence, and return
      shaping for the in-lock paths. Receives the original config.
    * `:already_refreshed` — builds the return value when another process
      already refreshed the token. Receives the original config and the
      freshly decrypted integration credentials.
    * `:fallback_refresh` (optional) — return shaping for the unlocked
      no-ids path; defaults to `:refresh`.
  """
  @type hooks :: %{
          required(:provider) => atom(),
          required(:refresh) => (config() -> result()),
          required(:already_refreshed) => (config(), decrypted() -> result()),
          optional(:fallback_refresh) => (config() -> result())
        }

  @doc """
  Returns whether `expires_at` is further out than the refresh buffer.

  `nil` (no known expiry) is treated as "not valid" so a refresh is forced.
  """
  @spec token_still_valid?(DateTime.t() | nil) :: boolean()
  def token_still_valid?(nil), do: false

  def token_still_valid?(expires_at) do
    buffer = DateTime.add(DateTime.utc_now(), @buffer_seconds, :second)
    DateTime.compare(expires_at, buffer) == :gt
  end

  @doc """
  Runs the shared locked, double-checked token-refresh flow.

  See the module docs for the full state machine. Returns whatever the
  provider's `:refresh`/`:already_refreshed` hooks return.

  ## Options

    * `:force` (default `false`) — bypass the validity double-check and always
      run the provider's `:refresh` hook, still under the per-integration lock.
      Use this on a post-401 path: the access token was *server-side* rejected,
      so the DB expiry buffer can't be trusted and an `:already_refreshed`
      short-circuit would just replay the same rejected token.
  """
  @spec refresh_with_lock(config(), hooks(), keyword()) :: result()
  def refresh_with_lock(config, hooks, opts \\ []) do
    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)
    force? = Keyword.get(opts, :force, false)

    if is_nil(integration_id) or is_nil(user_id) do
      fallback = Map.get(hooks, :fallback_refresh, hooks.refresh)
      fallback.(config)
    else
      Lock.with_lock(
        {hooks.provider, integration_id},
        fn -> check_and_refresh(config, integration_id, user_id, hooks, force?) end,
        mode: :blocking
      )
    end
  end

  defp check_and_refresh(config, integration_id, user_id, hooks, true) do
    # Forced path: the caller proved the access token is rejected server-side,
    # so we skip the validity short-circuit — but we still re-read the DB under
    # the lock. If a sibling process already rotated the token (the stored access
    # token differs from the one that triggered the 401), return the fresh token
    # without hitting OAuth again. Otherwise refresh with the DB-fresh credentials
    # so we never use a stale pre-rotation refresh token (Zoom rotates on every
    # refresh call).
    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, fresh_integration} ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(fresh_integration)
        stale_access_token = Map.get(config, :access_token)

        if decrypted.access_token != stale_access_token do
          # A sibling already refreshed — hand back the fresh token without
          # another OAuth round-trip.
          hooks.already_refreshed.(config, build_decrypted(fresh_integration, decrypted))
        else
          # Token is still the rejected one; refresh using the latest credentials
          # from the DB so we use the most recent refresh token.
          fresh_config =
            Map.merge(config, %{
              access_token: decrypted.access_token,
              refresh_token: decrypted.refresh_token
            })

          hooks.refresh.(fresh_config)
        end

      {:error, :not_found} ->
        hooks.refresh.(config)
    end
  end

  defp check_and_refresh(config, integration_id, user_id, hooks, false) do
    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, fresh_integration} ->
        decrypted = VideoIntegrationSchema.decrypt_credentials(fresh_integration)

        if token_still_valid?(decrypted.token_expires_at) do
          hooks.already_refreshed.(config, build_decrypted(fresh_integration, decrypted))
        else
          hooks.refresh.(config)
        end

      {:error, :not_found} ->
        hooks.refresh.(config)
    end
  end

  # Surfaces the integration's `oauth_scope` alongside the decrypted
  # credentials so providers that fold scope into their return value
  # (Google Meet) have it available without re-reading the integration.
  defp build_decrypted(fresh_integration, decrypted) do
    Map.put(decrypted, :oauth_scope, fresh_integration.oauth_scope)
  end
end
