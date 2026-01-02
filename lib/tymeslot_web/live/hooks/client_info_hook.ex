defmodule TymeslotWeb.Hooks.ClientInfoHook do
  @moduledoc """
  LiveView on_mount hook that captures client info during mount and stores it in assigns.

  Assigns set:
  - :client_ip
  - :user_agent
  - :detected_timezone (from connect params)
  """

  import Phoenix.Component
  import Phoenix.LiveView, only: [get_connect_params: 1]

  alias TymeslotWeb.Helpers.ClientIP

  @doc """
  Default on_mount handler. Must be run during LiveView mount.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    client_ip = ClientIP.get_from_mount(socket)
    user_agent = ClientIP.get_user_agent_from_mount(socket)

    connect_params = get_connect_params(socket) || %{}
    detected_timezone = Map.get(connect_params, "timezone")

    {:cont,
     assign(socket,
       client_ip: client_ip,
       user_agent: user_agent,
       detected_timezone: detected_timezone
     )}
  end
end
