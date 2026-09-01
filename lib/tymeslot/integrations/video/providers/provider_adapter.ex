defmodule Tymeslot.Integrations.Video.Providers.ProviderAdapter do
  @moduledoc """
  Adapter that wraps video provider calls with common functionality.

  This module provides a unified interface for all video providers,
  handling common concerns like error handling, logging, metrics, and
  provider lifecycle management.
  """

  require Logger
  alias Tymeslot.Infrastructure.CircuitBreakerHelpers
  alias Tymeslot.Infrastructure.Metrics
  alias Tymeslot.Infrastructure.VideoCircuitBreaker
  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Providers.ProviderRegistry

  @doc """
  Creates a new meeting room using the specified provider.

  Returns {:ok, MeetingContext.t()} or {:error, reason}.
  """
  @spec create_meeting_room(atom(), map()) :: {:ok, MeetingContext.t()} | {:error, term()}
  def create_meeting_room(provider_type, config) do
    Metrics.time_operation(:video_create_room, %{provider: provider_type}, fn ->
      Logger.info("Creating meeting room", provider: provider_type)

      with {:ok, provider_module} <- ProviderRegistry.get_provider(provider_type),
           :ok <- provider_module.validate_config(config),
           {:ok, room_data} <- create_room(provider_type, provider_module, config) do
        Logger.info("Successfully created meeting room",
          provider: provider_type,
          room_id: room_data.room_id || "unknown"
        )

        # Handle meeting created event
        provider_module.handle_meeting_event(:created, room_data, %{})

        {:ok,
         %MeetingContext{
           provider_type: provider_type,
           room_data: room_data,
           provider_module: provider_module
         }}
      else
        {:error, :unknown_provider} ->
          Logger.error("Unknown video provider", provider_type: provider_type)
          {:error, :unknown_provider}

        {:error, _reason} = error ->
          Logger.error("Failed to create meeting room",
            provider: provider_type,
            reason: inspect(error)
          )

          error
      end
    end)
  end

  @doc """
  Creates a join URL for a participant.
  """
  @spec create_join_url(MeetingContext.t(), String.t(), String.t(), atom(), DateTime.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_join_url(meeting_context, participant_name, participant_email, role, meeting_time) do
    %{
      provider_type: provider_type,
      room_data: room_data,
      provider_module: provider_module
    } = meeting_context

    Metrics.time_operation(:video_create_join_url, %{provider: provider_type}, fn ->
      Logger.debug("Creating join URL for participant",
        provider: provider_type,
        participant: participant_name,
        role: role
      )

      case provider_module.create_join_url(
             room_data,
             participant_name,
             participant_email,
             role,
             meeting_time
           ) do
        {:ok, join_url} ->
          Logger.debug("Successfully created join URL",
            provider: provider_type,
            participant: participant_name
          )

          {:ok, join_url}

        {:error, reason} = error ->
          Logger.error("Failed to create join URL",
            provider: provider_type,
            participant: participant_name,
            reason: inspect(reason)
          )

          error
      end
    end)
  end

  @doc """
  Extracts room ID from a meeting URL.
  """
  @spec extract_room_id(String.t()) :: String.t() | nil
  def extract_room_id(meeting_url) do
    # Try to detect provider from URL and extract room ID
    case detect_provider_from_url(meeting_url) do
      {:ok, provider_type} ->
        case ProviderRegistry.get_provider(provider_type) do
          {:ok, provider_module} ->
            provider_module.extract_room_id(meeting_url)

          {:error, _reason} ->
            Logger.warning("Failed to get provider for room ID extraction",
              provider_type: provider_type
            )

            nil
        end

      {:error, _reason} ->
        Logger.warning("Could not detect provider from URL", url: meeting_url)
        nil
    end
  end

  @doc """
  Validates if a URL is a valid meeting URL.
  """
  @spec valid_meeting_url?(String.t()) :: boolean()
  def valid_meeting_url?(meeting_url) do
    case detect_provider_from_url(meeting_url) do
      {:ok, provider_type} ->
        case ProviderRegistry.get_provider(provider_type) do
          {:ok, provider_module} ->
            provider_module.valid_meeting_url?(meeting_url)

          {:error, _reason} ->
            false
        end

      {:error, _reason} ->
        false
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

    case ProviderRegistry.test_provider_connection(provider_type, config) do
      {:ok, message} ->
        Logger.info("Connection test successful", provider: provider_type)
        {:ok, message}

      {:error, reason} = error ->
        Logger.error("Connection test failed",
          provider: provider_type,
          reason: inspect(reason)
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
    Metrics.time_operation(:video_update_room, %{provider: provider_type}, fn ->
      Logger.info("Updating meeting room", provider: provider_type, room_id: room_id)

      case ProviderRegistry.get_provider(provider_type) do
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

  Providers without a server-side meeting object return `:ok` without action.
  """
  @spec delete_meeting_room(atom(), String.t(), map()) :: :ok | {:error, term()}
  def delete_meeting_room(provider_type, room_id, config) do
    Metrics.time_operation(:video_delete_room, %{provider: provider_type}, fn ->
      Logger.info("Deleting meeting room", provider: provider_type, room_id: room_id)

      case ProviderRegistry.get_provider(provider_type) do
        {:ok, provider_module} ->
          if callback_exported?(provider_module, :delete_meeting_room, 2) do
            with_breaker(provider_type, config, fn ->
              # Optional callback resolved at runtime via the guard above; apply/3
              # keeps the static type checker from flagging providers that omit it.
              # credo:disable-for-next-line Credo.Check.Refactor.Apply
              apply(provider_module, :delete_meeting_room, [room_id, config])
            end)
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

  @doc """
  Handles meeting lifecycle events.
  """
  @spec handle_meeting_event(MeetingContext.t(), atom(), map()) :: :ok | {:error, term()}
  def handle_meeting_event(meeting_context, event, additional_data \\ %{}) do
    %{
      provider_type: provider_type,
      room_data: room_data,
      provider_module: provider_module
    } = meeting_context

    Logger.info("Handling meeting event",
      provider: provider_type,
      event: event,
      room_id: room_data.room_id || "unknown"
    )

    case provider_module.handle_meeting_event(event, room_data, additional_data) do
      :ok ->
        Logger.debug("Successfully handled meeting event",
          provider: provider_type,
          event: event
        )

        :ok

      {:error, reason} = error ->
        Logger.error("Failed to handle meeting event",
          provider: provider_type,
          event: event,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Generates meeting metadata for display purposes.
  """
  @spec generate_meeting_metadata(MeetingContext.t()) :: map()
  def generate_meeting_metadata(meeting_context) do
    %{
      provider_type: provider_type,
      room_data: room_data,
      provider_module: provider_module
    } = meeting_context

    base_metadata = provider_module.generate_meeting_metadata(room_data)

    Map.merge(base_metadata, %{
      provider_type: provider_type,
      provider_name: provider_module.display_name()
    })
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
      # `{:error, reason}` inside `VideoCircuitBreaker`/`CircuitBreakerHelpers`.
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
    do: CircuitBreakerHelpers.host_from_base_url(base_url)

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

      {:error, _reason} = error ->
        error
    end
  end

  # function_exported?/3 returns false for modules that haven't been loaded
  # yet, which silently turns optional callbacks into no-ops in tests that
  # haven't touched the provider module before. Force-load first.
  defp callback_exported?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp detect_provider_from_url(meeting_url) when is_binary(meeting_url) do
    case find_matching_provider(meeting_url) do
      {:ok, provider} -> {:ok, provider}
      :not_found -> {:error, "Unknown provider"}
    end
  end

  defp detect_provider_from_url(_arg), do: {:error, "Invalid URL"}

  defp find_matching_provider(meeting_url) do
    Enum.find_value(ProviderConfig.all_providers_with_dev(), :not_found, fn provider_type ->
      with module when is_atom(module) <- ProviderConfig.get_provider_module(provider_type),
           true <- module != nil,
           true <- Code.ensure_loaded?(module),
           true <- function_exported?(module, :url_patterns, 0),
           # credo:disable-for-next-line Credo.Check.Refactor.Apply
           patterns when patterns != [] <- apply(module, :url_patterns, []),
           true <- Enum.any?(patterns, &String.contains?(meeting_url, &1)) do
        {:ok, provider_type}
      else
        _other -> nil
      end
    end)
  end
end
