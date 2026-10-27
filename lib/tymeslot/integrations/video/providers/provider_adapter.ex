defmodule Tymeslot.Integrations.Video.Providers.ProviderAdapter do
  @moduledoc """
  Adapter that wraps video provider calls with common functionality.

  This module provides a unified interface for all video providers,
  handling common concerns like error handling, logging, metrics, and
  provider lifecycle management.

  ## Room ids are never logged

  For every link-based provider the room id *is* the join link, so a log sink
  holding it hands whoever can read it a way into the call. The rule is
  provider-wide rather than per-provider, because a per-provider rule is one the
  next provider added here forgets: log `Redactor.fingerprint(room_id)` under a
  `room_ref` key, never the id itself. Nothing in these logs needs the real
  value; `meeting_id` and `integration_id` correlate with the database, and the
  fingerprint ties lines about one room together.
  """

  require Logger
  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Infrastructure.ProviderBreakers
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.ProviderConfig

  @doc """
  Creates a new meeting room using the specified provider.

  Returns {:ok, MeetingContext.t()} or {:error, reason}.
  """
  @spec create_meeting_room(atom(), map()) :: {:ok, MeetingContext.t()} | {:error, term()}
  def create_meeting_room(provider_type, config) do
    timed(:create_room, provider_type, fn ->
      # A failure is the caller's to log, once, with what the room was for.
      Logger.info("Creating meeting room", provider: provider_type)

      with {:ok, provider_module} <- ProviderConfig.get_provider(provider_type),
           :ok <- provider_module.validate_config(config),
           {:ok, room_data} <- create_room(provider_type, provider_module, config) do
        Logger.info("Successfully created meeting room",
          provider: provider_type,
          room_ref: Redactor.fingerprint(room_data.room_id)
        )

        {:ok,
         %MeetingContext{
           provider_type: provider_type,
           room_data: room_data,
           provider_module: provider_module
         }}
      end
    end)
  end

  @doc """
  Creates a join URL for a participant.
  """
  @spec create_join_url(MeetingContext.t(), String.t(), String.t(), String.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_join_url(meeting_context, participant_name, participant_email, role, meeting_time) do
    %{
      provider_type: provider_type,
      room_data: room_data,
      provider_module: provider_module
    } = meeting_context

    timed(:create_join_url, provider_type, fn ->
      # The role and room say whose link this is without copying the
      # participant's name into the log sink, where it outlives the account it
      # belongs to.
      Logger.debug("Creating join URL for participant",
        provider: provider_type,
        role: role,
        room_ref: Redactor.fingerprint(room_data.room_id)
      )

      # A failure is `VideoRooms`' to log, once, with the fallback it chose.
      with {:ok, _join_url} = ok <-
             provider_module.create_join_url(
               room_data,
               participant_name,
               participant_email,
               role,
               meeting_time
             ) do
        Logger.debug("Successfully created join URL",
          provider: provider_type,
          role: role,
          room_ref: Redactor.fingerprint(room_data.room_id)
        )

        ok
      end
    end)
  end

  @doc """
  The context's join URL for a recipient it cannot name — a booking's guests,
  and a calendar event's description — as
  `ProviderBehaviour.shared_join_url/2` describes it.

  Providers that do not implement the optional callback answer with the
  room's own URL, which is what they handed out before it existed, so a
  provider whose links carry no credential is unaffected by construction
  rather than by the caller remembering to ask first.
  """
  @spec shared_join_url(MeetingContext.t(), DateTime.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def shared_join_url(
        %MeetingContext{provider_module: provider_module, room_data: room_data},
        meeting_time
      ) do
    if callback_exported?(provider_module, :shared_join_url, 2) do
      # Optional callback resolved at runtime via the guard above; apply/3
      # keeps the static type checker from flagging providers that omit it.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(provider_module, :shared_join_url, [room_data, meeting_time])
    else
      {:ok, room_data.meeting_url}
    end
  end

  @doc """
  Whether the context's join URLs stop working some time after the meeting
  time they were built for, so a reschedule has to build them again.

  Providers that do not implement the optional `time_bound_join_urls?/1`
  callback answer `false`.
  """
  @spec time_bound_join_urls?(MeetingContext.t()) :: boolean()
  def time_bound_join_urls?(%MeetingContext{
        provider_module: provider_module,
        room_data: room_data
      }) do
    if callback_exported?(provider_module, :time_bound_join_urls?, 1) do
      # Optional callback resolved at runtime via the guard above; apply/3
      # keeps the static type checker from flagging providers that omit it.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(provider_module, :time_bound_join_urls?, [room_data.provider_config || %{}])
    else
      false
    end
  end

  @doc """
  Extracts the room id from a meeting URL using `provider_type`'s own rules.

  Dispatches straight to the named provider, so a URL another provider would
  have claimed by substring is still parsed by the one that actually issued it.
  Accepts the atom or the string form, since persisted integrations carry the
  string. Returns `nil` for an unknown provider or a non-binary URL.
  """
  @spec extract_room_id(String.t(), atom() | String.t()) :: String.t() | nil
  def extract_room_id(meeting_url, provider_type) when is_binary(meeting_url) do
    with {:ok, type} <- ProviderConfig.parse_known(provider_type),
         {:ok, provider_module} <- ProviderConfig.get_provider(type) do
      provider_module.extract_room_id(meeting_url)
    else
      {:error, _reason} ->
        Logger.warning("Failed to get provider for room ID extraction",
          provider_type: provider_type
        )

        nil
    end
  end

  def extract_room_id(_meeting_url, _provider_type), do: nil

  # The one place a provider's network connection test is run; every route to
  # it goes through `Tymeslot.Integrations.Video.Connection`, which validates
  # the config and decides whether and to whom the test is rate-limited.
  defp run_connection_test(provider_type, config) do
    with {:ok, module} <- ProviderConfig.get_provider(provider_type) do
      module.perform_connection_test(config)
    end
  end

  @doc """
  Tests connection to a video provider.

  Not validated or rate-limited here: `Tymeslot.Integrations.Video.Connection.probe/3`
  runs `validate_config/1` first and is the choke point that decides whether
  and to whom the test is charged.
  """
  @spec test_connection(atom(), map()) :: {:ok, String.t()} | {:error, term()}
  def test_connection(provider_type, config) do
    Logger.info("Testing connection to provider", provider: provider_type)

    case run_connection_test(provider_type, config) do
      {:ok, message} ->
        Logger.info("Connection test successful", provider: provider_type)
        {:ok, message}

      {:error, reason} = error ->
        Logger.error("Connection test failed",
          provider: provider_type,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  @doc """
  Updates an existing meeting room on the provider's side.

  Providers without a server-side meeting object return `:ok` without action.
  """
  @spec update_meeting_room(atom(), String.t(), map()) :: :ok | {:error, term()}
  def update_meeting_room(provider_type, room_id, config) do
    timed(:update_room, provider_type, fn ->
      Logger.info("Updating meeting room",
        provider: provider_type,
        room_ref: Redactor.fingerprint(room_id)
      )

      case ProviderConfig.get_provider(provider_type) do
        {:ok, provider_module} ->
          if callback_exported?(provider_module, :update_meeting_room, 2) do
            with_breaker(provider_type, config, fn ->
              # Optional callback resolved at runtime via the guard above; apply/3
              # keeps the static type checker from flagging providers that omit it.
              # credo:disable-for-next-line Credo.Check.Refactor.Apply
              apply(provider_module, :update_meeting_room, [room_id, config])
            end)
          else
            Logger.debug("Provider does not support update_meeting_room; treating as no-op",
              provider: provider_type
            )

            :ok
          end

        {:error, _reason} = error ->
          Logger.error("Unknown video provider", provider_type: provider_type)
          error
      end
    end)
  end

  @doc """
  Deletes a meeting room on the provider's side.

  Providers without a server-side meeting object return `:ok` without action,
  and so does a room the provider no longer has, which is what a delete wants:
  deleting stays idempotent whichever way a provider words "not found".
  """
  @spec delete_meeting_room(atom(), String.t(), map()) :: :ok | {:error, term()}
  def delete_meeting_room(provider_type, room_id, config) do
    timed(:delete_room, provider_type, fn ->
      Logger.info("Deleting meeting room",
        provider: provider_type,
        room_ref: Redactor.fingerprint(room_id)
      )

      case ProviderConfig.get_provider(provider_type) do
        {:ok, provider_module} ->
          if callback_exported?(provider_module, :delete_meeting_room, 2) do
            result =
              with_breaker(provider_type, config, fn ->
                # Optional callback resolved at runtime via the guard above; apply/3
                # keeps the static type checker from flagging providers that omit it.
                # credo:disable-for-next-line Credo.Check.Refactor.Apply
                apply(provider_module, :delete_meeting_room, [room_id, config])
              end)

            already_gone_is_deleted(result, provider_type, room_id)
          else
            Logger.debug("Provider does not support delete_meeting_room; treating as no-op",
              provider: provider_type
            )

            :ok
          end

        {:error, _reason} = error ->
          Logger.error("Unknown video provider", provider_type: provider_type)
          error
      end
    end)
  end

  # Private helper functions

  # The three operations that reach a provider's API run through its circuit
  # breaker, so a provider outage stops being hammered by every booking that
  # wants a room. Registry lookup and config validation stay outside it: those
  # fail for our own reasons and must not count against the provider.
  #
  # `test_connection/2` deliberately has no breaker. It is how an operator asks
  # whether the provider is reachable, and refusing it while the circuit is open
  # would withhold exactly the answer they asked for.
  #
  # Room creation additionally splits per-tenant work (credential/scope
  # resolution) out of the breaker-guarded call itself — see `create_room/3`.
  defp with_breaker(provider_type, config, fun) do
    if ProviderConfig.circuit_breaker_enabled?(provider_type) do
      VideoCircuitBreaker.with_breaker(provider_type, [host: breaker_host(config)], fun)
    else
      # The breaker-enabled path unwraps `{:provider_error, reason}` back to
      # `{:error, reason}` inside `ProviderBreakers`.
      # With the breaker disabled that unwrap never runs, so `create_room/3`
      # would otherwise hand `{:provider_error, _}` straight to
      # `create_meeting_room/2`'s `with/else`, which has no clause for it and
      # raises `WithClauseError`. Unwrap here too so the tag stays an internal
      # detail of `with_breaker/3` regardless of which arm ran.
      case fun.() do
        {:provider_error, reason} -> {:error, reason}
        other -> other
      end
    end
  end

  # Self-hosted providers (MiroTalk) carry a per-tenant `base_url`; extracting
  # its host lets `VideoCircuitBreaker` key the breaker per host instead of
  # sharing one breaker across every tenant on the provider. OAuth providers'
  # configs have no `base_url`, so this is a no-op for them.
  defp breaker_host(%{base_url: base_url}) when is_binary(base_url),
    do: ProviderBreakers.host_from_base_url(base_url)

  defp breaker_host(_config), do: nil

  # A provider's `create_meeting_room/1` callback typically bundles per-tenant
  # credential/scope resolution with the actual outbound API call, so wrapping
  # the whole thing in the breaker lets one tenant's bad credential (retried by
  # Oban) open the shared, provider-wide breaker and stop room creation for
  # every tenant.
  #
  # Providers may opt out of that by exposing two duck-typed functions instead
  # of doing everything in `create_meeting_room/1`:
  #
  #   * `precheck_create_meeting_room/1` — runs entirely outside the breaker.
  #     Returns `{:ok, token}` to proceed, `{:error, reason}` for a per-tenant
  #     failure (bad scope, revoked grant) that must never count against the
  #     breaker, or `{:provider_error, reason}` for a failure that looks like
  #     the provider's own host (e.g. its OAuth endpoint) is having trouble —
  #     handed to the breaker below so it still gets recorded.
  #   * `finish_create_meeting_room/2` — the actual API call, given the
  #     already-resolved token, run behind the breaker.
  #
  # Providers that don't implement both keep the old all-in-one behaviour
  # unchanged.
  defp create_room(provider_type, provider_module, config) do
    if callback_exported?(provider_module, :precheck_create_meeting_room, 1) and
         callback_exported?(provider_module, :finish_create_meeting_room, 2) do
      create_room_with_precheck(provider_type, provider_module, config)
    else
      with_breaker(provider_type, config, fn -> provider_module.create_meeting_room(config) end)
    end
  end

  defp create_room_with_precheck(provider_type, provider_module, config) do
    case provider_module.precheck_create_meeting_room(config) do
      {:ok, token} ->
        with_breaker(provider_type, config, fn ->
          provider_module.finish_create_meeting_room(token, config)
        end)

      {:provider_error, reason} ->
        # Let the breaker witness the failure without repeating the network
        # call that already happened during the precheck. Tagged
        # `{:provider_error, reason}` rather than `{:error, reason}` so
        # `BreakerOutcome` classifies it `:failure` outright instead of
        # re-guessing from `reason`'s shape; `with_breaker`/`VideoCircuitBreaker`
        # unwrap the tag back to a plain `{:error, reason}` for the caller.
        with_breaker(provider_type, config, fn -> {:provider_error, reason} end)

      {:error, reason} = error ->
        if BreakerOutcome.permanent_credential_error?(reason),
          do: refuse_revoked_grant(provider_module, config),
          else: error
    end
  end

  # The provider refused the grant for good while refreshing it: no retry
  # will mint a token, and only the owner reconnecting fixes it. So the
  # integration is flagged now (which also emails the owner, once), and the
  # failure comes back as `:unauthorized`, the reason room creation treats as
  # final, rather than as provider text it would retry as an outage.
  defp refuse_revoked_grant(provider_module, config) do
    if callback_exported?(provider_module, :flag_revoked_token, 1),
      do: provider_module.flag_revoked_token(config)

    {:error, :unauthorized}
  end

  # `:meeting_not_found` stays an error for an update, where it tells the
  # caller the booking's room is gone.
  defp already_gone_is_deleted({:error, :meeting_not_found}, provider_type, room_id) do
    Logger.info("Meeting room already gone on the provider, treating as deleted",
      provider: provider_type,
      room_ref: Redactor.fingerprint(room_id)
    )

    :ok
  end

  defp already_gone_is_deleted(result, _provider_type, _room_id), do: result

  # Each room operation's telemetry event, `[:tymeslot, :video, operation]`.
  defp timed(operation, provider_type, fun),
    do:
      Metrics.time_operation(operation, %{provider: provider_type}, fun,
        prefix: [:tymeslot, :video]
      )

  # function_exported?/3 returns false for modules that haven't been loaded
  # yet, which silently turns optional callbacks into no-ops in tests that
  # haven't touched the provider module before. Force-load first.
  defp callback_exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
