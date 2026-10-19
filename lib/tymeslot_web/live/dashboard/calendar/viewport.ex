defmodule TymeslotWeb.Dashboard.Calendar.Viewport do
  @moduledoc """
  Whether the calendar is on a phone, which decides one thing on the server:
  the view. A week shows as three days on a phone (`Period.for_viewport/2`),
  without touching the URL or the stored default view. The layout never
  depends on it; CSS shows the phone or the desktop chrome.

  The first guess comes from the socket: the `viewport` connect param the
  browser sends (`matchMedia` on the same query as the CSS), or, on the
  dead render, the user agent (`ClientInfoHook`). `DashboardLive` passes it
  down as `viewport_hint`. Once the hook has reported (`calendar:ready`,
  then `calendar:viewport` whenever the width crosses the boundary) its
  answer stands, and the parent's hint, re-sent on every render, is
  ignored.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias TymeslotWeb.Dashboard.Calendar.SurfaceData

  @type t :: :phone | :wide
  @type socket :: Phoenix.LiveView.Socket.t()

  # "Mobi" is in every phone browser's user agent ("Mobile", "Mobile Safari",
  # Android phones' "Mobile") and in no tablet's: Android tablets leave it
  # out, and an iPad asks for the desktop site as a Mac.
  @phone_agents ["Mobi", "iPhone"]

  @doc "The first guess, from the socket's connect params or the user agent."
  @spec from_connect(map() | nil, String.t() | nil) :: t()
  def from_connect(%{"viewport" => "phone"}, _user_agent), do: :phone
  def from_connect(%{"viewport" => "wide"}, _user_agent), do: :wide

  def from_connect(_params, user_agent) when is_binary(user_agent),
    do: if(String.contains?(user_agent, @phone_agents), do: :phone, else: :wide)

  def from_connect(_params, _user_agent), do: :wide

  @doc "Takes the parent's `viewport_hint` until the hook has reported."
  @spec adopt_hint(socket()) :: socket()
  def adopt_hint(%{assigns: %{viewport_reported: true}} = socket), do: socket
  def adopt_hint(socket), do: assign(socket, :viewport, hint(socket.assigns[:viewport_hint]))

  @doc """
  The hook's answer (`phone?`). When the view it implies differs from the
  one shown, the surface follows it as it follows the URL (and pushes the
  period or the events). Anything but a boolean changes nothing.
  """
  @spec report(socket(), term()) :: socket()
  def report(socket, phone?) when is_boolean(phone?) do
    socket =
      assign(socket, viewport: if(phone?, do: :phone, else: :wide), viewport_reported: true)

    if socket.assigns.ready? and view_changed?(socket.assigns),
      do: SurfaceData.follow(socket),
      else: socket
  end

  def report(socket, _not_a_boolean), do: socket

  defp hint(:phone), do: :phone
  defp hint(_wide_or_missing), do: :wide

  defp view_changed?(assigns) do
    {view, _date} = SurfaceData.target(assigns)
    view != assigns.view
  end
end
