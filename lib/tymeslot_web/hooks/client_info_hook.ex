defmodule TymeslotWeb.Hooks.ClientInfoHook do
  @moduledoc """
  LiveView on_mount hook that captures client info during mount and stores it in assigns.

  Assigns set:
  - :client_ip
  - :user_agent
  - :detected_timezone (from connect params)
  - :viewport (`:phone` or `:wide`, see `viewport_from_connect/2`)
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
       detected_timezone: detected_timezone,
       viewport: viewport_from_connect(connect_params, user_agent)
     )}
  end

  # "Mobi" is in every phone browser's user agent ("Mobile", "Mobile Safari",
  # Android phones' "Mobile") and in no tablet's: Android tablets leave it
  # out, and an iPad asks for the desktop site as a Mac.
  @phone_agents ["Mobi", "iPhone"]

  @doc """
  The first guess at the viewport, from the socket's connect params (the
  browser's `matchMedia` answer) or, on the dead render, the user agent.
  """
  @spec viewport_from_connect(map() | nil, String.t() | nil) :: :phone | :wide
  def viewport_from_connect(%{"viewport" => "phone"}, _user_agent), do: :phone
  def viewport_from_connect(%{"viewport" => "wide"}, _user_agent), do: :wide

  def viewport_from_connect(_params, user_agent) when is_binary(user_agent),
    do: if(String.contains?(user_agent, @phone_agents), do: :phone, else: :wide)

  def viewport_from_connect(_params, _user_agent), do: :wide
end
