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
  alias TymeslotWeb.Hooks.ClientInfoHook

  @type t :: :phone | :wide
  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "The first guess, from the socket's connect params or the user agent."
  @spec from_connect(map() | nil, String.t() | nil) :: t()
  defdelegate from_connect(params, user_agent), to: ClientInfoHook, as: :viewport_from_connect

  @doc "Takes the parent's `viewport_hint` until the hook has reported."
  @spec adopt_hint(socket()) :: socket()
  def adopt_hint(%{assigns: %{viewport_reported: true}} = socket), do: socket
  def adopt_hint(socket), do: assign(socket, :viewport, hint(socket.assigns[:viewport_hint]))

  @doc """
  The hook's answer (`phone?`). When the view it implies differs from the
  one shown, the surface follows it as it follows the URL (and pushes the
  period or the events) but keeps the preview and any open sheet, unless `push?` is false: `calendar:ready` replies
  with the payload itself, so the correction is only assigned. Anything but
  a boolean changes nothing.
  """
  @spec report(socket(), term(), boolean()) :: socket()
  def report(socket, phone?, push? \\ true)

  def report(socket, phone?, push?) when is_boolean(phone?) do
    socket =
      assign(socket, viewport: if(phone?, do: :phone, else: :wide), viewport_reported: true)

    cond do
      not (socket.assigns.ready? and view_changed?(socket.assigns)) -> socket
      push? -> SurfaceData.follow(socket, keep_open?: true)
      true -> socket |> SurfaceData.apply_params(keep_open?: true) |> SurfaceData.load_window()
    end
  end

  def report(socket, _not_a_boolean, _push?), do: socket

  defp hint(:phone), do: :phone
  defp hint(_wide_or_missing), do: :wide

  defp view_changed?(assigns) do
    {view, _date} = SurfaceData.target(assigns)
    view != assigns.view
  end
end
