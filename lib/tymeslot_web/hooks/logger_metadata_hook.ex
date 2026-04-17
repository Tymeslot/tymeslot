defmodule TymeslotWeb.Hooks.LoggerMetadataHook do
  @moduledoc """
  LiveView hook that sets Logger process metadata for correlation and user tracking.

  LiveView processes are separate Erlang processes that don't inherit Logger metadata
  from the HTTP request that initiated them. This hook ensures every LiveView process
  has a `correlation_id` (generated fresh per mount) and, when available, a `user_id`
  in its Logger metadata — matching the context that Plug-based requests get via
  `CorrelationId` and `SetLoggerMetadata`.
  """

  alias Tymeslot.Infrastructure.CorrelationId

  require Logger

  @doc """
  Sets `correlation_id` and `user_id` in Logger metadata for the LiveView process.

  Always returns `{:cont, socket}` — purely observational, never halts navigation.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    # Reset per-mount keys so a reused LiveView process cannot inherit the
    # previous mount's user_id or correlation_id.
    Logger.metadata(user_id: nil, correlation_id: nil)

    {socket, correlation_id} = CorrelationId.ensure(socket)

    CorrelationId.put_in_process(correlation_id)
    CorrelationId.add_to_logger_metadata(correlation_id)

    if user = socket.assigns[:current_user] do
      Logger.metadata(user_id: user.id)
    end

    {:cont, socket}
  end
end
