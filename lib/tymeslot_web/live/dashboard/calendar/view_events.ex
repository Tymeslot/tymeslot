defmodule TymeslotWeb.Dashboard.Calendar.ViewEvents do
  @moduledoc """
  The calendar surface's events about how a view is drawn rather than what
  it holds: `calendar:agenda_more`, the agenda asking for its next weeks
  (`AgendaLoader`), and `calendar:viewport`, the hook's width crossing the
  phone boundary (`Viewport`). `CalendarSurface` routes every event in its
  `@view_events` here.
  """

  alias TymeslotWeb.Dashboard.Calendar.AgendaLoader
  alias TymeslotWeb.Dashboard.Calendar.Viewport

  @type socket :: Phoenix.LiveView.Socket.t()

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()} | {:reply, map(), socket()}
  def handle("calendar:agenda_more", %{"through" => through}, socket) when is_binary(through) do
    {reply, socket} = AgendaLoader.more(socket, through)
    {:reply, reply, socket}
  end

  # The hook's width crossed the phone boundary (debounced in the hook).
  def handle("calendar:viewport", params, socket),
    do: {:noreply, Viewport.report(socket, params["phone"])}

  def handle("calendar:agenda_more", _params, socket),
    do: {:reply, %{payload: nil, done: false}, socket}
end
