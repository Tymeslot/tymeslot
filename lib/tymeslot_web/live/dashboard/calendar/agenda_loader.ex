defmodule TymeslotWeb.Dashboard.Calendar.AgendaLoader do
  @moduledoc """
  The agenda's growing window. An agenda first loads `Period.window/4`
  (four weeks before its date to eight after); as its end scrolls into
  sight the `CalendarCanvas` hook asks for more with `calendar:agenda_more`,
  naming the last day it holds in a row, and `more/2` loads from the day
  after the loaded window to four weeks past that day, never further than
  `Period.agenda_max_days/0` from the agenda's date ("Show later" moves the
  date on from there).

  The window stays one contiguous range, so the furthest day loaded is all
  that needs remembering (`:agenda_through`); `extend_window/2` keeps it in
  the window `SurfaceData` reloads after a sync, so the list never shrinks
  under the organiser. A new period resets it (`SurfaceData.apply_params/2`).
  """

  import Phoenix.Component, only: [assign: 2]

  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  The next chunk for an agenda whose browser holds days up to `through`
  (ISO): `{%{payload, done}, socket}`. `payload` is shaped like
  `calendar:events` for the chunk alone (`reset: false`), or nil when the
  surface is not on an agenda, `through` is before this agenda's window
  (the request was meant for another agenda), or the cap is reached. `done`
  is true once the window reaches the cap.
  """
  @spec more(socket(), String.t()) :: {map(), socket()}
  def more(%{assigns: %{view: :agenda, window: %Date.Range{}}} = socket, through) do
    case chunk(socket.assigns, through) do
      %Date.Range{} = chunk -> extend(socket, chunk)
      nil -> {%{payload: nil, done: done?(socket.assigns)}, socket}
    end
  end

  def more(socket, _through), do: {%{payload: nil, done: false}, socket}

  @doc "`window` reaching the furthest day an agenda has loaded, when it has grown."
  @spec extend_window(map(), Date.Range.t()) :: Date.Range.t()
  def extend_window(%{view: :agenda, agenda_through: %Date{} = through}, %Date.Range{} = window) do
    if Date.compare(through, window.last) == :gt,
      do: Date.range(window.first, through),
      else: window
  end

  def extend_window(_assigns, window), do: window

  # The days after the loaded window, up to four weeks past the furthest day
  # the browser holds (which can run past the window when an earlier visit
  # left later days in its cache) and no further than the cap.
  defp chunk(%{window: window} = assigns, through) do
    cap = cap(assigns)

    case Date.from_iso8601(through) do
      {:ok, held} ->
        if Date.compare(held, window.first) != :lt and Date.compare(window.last, cap) == :lt do
          furthest = Enum.max([held, window.last], Date)
          last = Enum.min([Date.add(furthest, Period.agenda_days()), cap], Date)
          Date.range(Date.add(window.last, 1), last)
        end

      {:error, _reason} ->
        nil
    end
  end

  # The chunk's events join the window's (an event that crosses into the
  # chunk is already there), and the payload carries every event touching
  # the chunk, since the hook replaces what it held for those days.
  defp extend(socket, chunk) do
    %{window: window, window_events: held} = socket.assigns
    loaded = SurfaceData.list_events(socket.assigns, chunk)
    known = MapSet.new(held, &EventPayload.id/1)
    added = Enum.reject(loaded, &MapSet.member?(known, EventPayload.id(&1)))

    socket =
      socket
      |> assign(
        window: Date.range(window.first, chunk.last),
        window_events: held ++ added,
        locked_uids:
          MapSet.union(socket.assigns.locked_uids, SurfaceData.locked_uids(socket.assigns, added)),
        agenda_through: chunk.last
      )
      |> SurfaceData.refilter()

    payload =
      SurfaceData.payload(
        %{socket.assigns | window: chunk, events: SurfaceData.visible(socket.assigns, loaded)},
        false
      )

    {%{payload: payload, done: done?(socket.assigns)}, socket}
  end

  defp done?(%{window: window} = assigns), do: Date.compare(window.last, cap(assigns)) != :lt

  defp cap(%{date: date}), do: Date.add(date, Period.agenda_max_days() - 1)
end
