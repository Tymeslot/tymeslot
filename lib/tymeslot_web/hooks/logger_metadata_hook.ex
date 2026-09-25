defmodule TymeslotWeb.Hooks.LoggerMetadataHook do
  @moduledoc """
  LiveView hook that sets Logger metadata and error context for correlation and
  user tracking.

  LiveView processes are separate Erlang processes that don't inherit Logger metadata
  from the HTTP request that initiated them. This hook ensures every LiveView process
  has a `correlation_id` (generated fresh per mount) and, when available, a `user_id`,
  in its Logger metadata and in the context ErrorTracker stores with any exception
  the LiveView raises, matching the context that Plug-based requests get via
  `CorrelationId` and `SetLoggerMetadata`.
  """

  import Phoenix.LiveView, only: [connected?: 1]

  alias Tymeslot.Infrastructure.CorrelationId
  alias Tymeslot.Infrastructure.ErrorTracking

  @doc """
  Sets `correlation_id` and `user_id` for the LiveView process through
  `Tymeslot.Infrastructure.ErrorTracking.put_context/1`.

  Always returns `{:cont, socket}` — purely observational, never halts navigation.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    # On the initial HTTP (dead) render the LiveView mounts in the same process
    # as the Plug pipeline, where `CorrelationId` has already set a correlation
    # id in the process dictionary. Adopt it so the request's start and stop log
    # lines share one id.
    #
    # On a live (connected) WebSocket mount we always mint a fresh id — even if
    # the process dictionary already holds one from a prior mount. The channel
    # process is reused across live_redirect/push_navigate, so the process-dict
    # value would be the *previous* mount's id, causing two navigations to share
    # a single correlation_id (tracing noise). Generating fresh per connected
    # mount matches the module's documented intent.
    {socket, correlation_id} =
      if connected?(socket) do
        CorrelationId.ensure(socket)
      else
        case CorrelationId.get_from_process() do
          nil -> CorrelationId.ensure(socket)
          existing -> {CorrelationId.put_in_socket(socket, existing), existing}
        end
      end

    CorrelationId.put_in_process(correlation_id)

    # Both keys are always set, `user_id` as `nil` for a visitor, so a reused
    # LiveView process cannot inherit the previous mount's values.
    ErrorTracking.put_context(correlation_id: correlation_id, user_id: user_id(socket))

    {:cont, socket}
  end

  defp user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _no_user -> nil
    end
  end
end
