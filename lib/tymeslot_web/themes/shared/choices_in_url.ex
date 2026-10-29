defmodule TymeslotWeb.Themes.Shared.ChoicesInUrl do
  @moduledoc """
  Keeps a booking page's URL in step with the visitor's choices, so a page
  remounted from it lands where the visitor was.

  Moving between moments changes assigns only, and a socket that reconnects
  (a network blip, a laptop waking, a deploy draining the node) mounts the
  LiveView again from the URL in the address bar. After every choice the
  page patches its own URL to carry them (`PathHandlers.choices_query/1`):
  the meeting type, length, day, time and timezone, and on a paged journey
  the moment on screen. The patch replaces the history entry rather than
  adding one, so Back still leaves the page, and inside an embed it changes
  the iframe's URL alone, never the parent page's.

  A patch runs `handle_params/3` again, which would apply the URL from the
  start: the route's entry moment again, its facts entered again (a fresh
  submission token, the calendar refetched). The page's own patch carries
  nothing the socket does not already hold, so `own_patch?/2` recognises it
  and the page applies none of it.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2, put_flash: 3]

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.PathHandlers

  # The routes whose page holds a booking in progress. The confirmation's
  # route (`/:username/thank-you`) holds one already made, named by its own
  # query.
  @booking_routes [:overview, :schedule, :booking]

  @doc """
  Patches the page's URL to carry the visitor's choices when they changed
  since it last did. Takes a socket or a `{:noreply, socket}` reply; a page
  already navigating elsewhere is left alone.
  """
  @spec sync(Socket.t()) :: Socket.t()
  @spec sync({:noreply, Socket.t()}) :: {:noreply, Socket.t()}
  def sync({:noreply, socket}), do: {:noreply, sync(socket)}

  def sync(%Socket{} = socket) do
    if syncable?(socket) do
      patch_if_changed(socket, PathHandlers.choices_query(socket))
    else
      socket
    end
  end

  def sync(other), do: other

  @doc """
  Whether `params` are those of the page's own last patch, which carry
  nothing the socket does not hold already.
  """
  @spec own_patch?(Socket.t(), map()) :: boolean()
  def own_patch?(socket, params) do
    query = socket.assigns[:own_patch_query]
    is_map(query) and query == PathHandlers.query_params(params)
  end

  @doc "Forgets the page's last patch, once the URL has moved on from it."
  @spec forget(Socket.t()) :: Socket.t()
  def forget(socket), do: assign(socket, :own_patch_query, nil)

  defp syncable?(socket) do
    assigns = socket.assigns

    is_nil(socket.redirected) and is_map(assigns[:journey]) and
      assigns[:live_action] in @booking_routes and is_binary(assigns[:username_context])
  end

  defp patch_if_changed(socket, query) do
    if query == (socket.assigns[:page_query_params] || %{}) do
      socket
    else
      path = PathHandlers.page_path(socket)
      to = if query == %{}, do: path, else: "#{path}?#{URI.encode_query(query)}"

      socket
      |> assign(:own_patch_query, query)
      |> keep_flash()
      |> push_patch(to: to, replace: true)
    end
  end

  # A patch keeps only the flash set in the same callback, and clears the
  # rest as a navigation would. The page's own patch is no navigation: its
  # first one comes as the page connects, so a flash the page arrived with
  # would vanish before the visitor could read it.
  defp keep_flash(socket) do
    Enum.reduce(socket.assigns.flash, socket, fn {key, message}, acc ->
      put_flash(acc, key, message)
    end)
  end
end
