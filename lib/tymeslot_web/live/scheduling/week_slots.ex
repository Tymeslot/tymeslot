defmodule TymeslotWeb.Live.Scheduling.WeekSlots do
  @moduledoc """
  A week of free times for the scheduling flow: the `:week_slots` a week view
  renders (`TymeslotWeb.Themes.Shared.Components.WeekGrid`), for
  `:current_week_start`.

  Nothing fetches a week until a theme asks for one with the canonical
  `load_week` event (`load/1`), so a theme with no week view never pays for
  it: `:week_slots` stays nil and every refetch below is a no-op. Once it is
  set it follows the page: week navigation, a timezone change, a calendar
  sync and every arrival at the schedule step fetch the week again
  (`refetch/1`), and so does the day the page lands the booker on when it is
  in another week (`follow_week/1`).

  The fetch is `Tymeslot.Availability.Offer.slots_for_range/4`, whose days are
  exactly what `slots_for_date/3` offers, run with `start_async/3` under
  `{:week_slots, week_start}`. `start_async/3` under another name leaves a
  task in flight alone, so each fetch first cancels the previous week's with
  `cancel_async/3`; and `handle_async/3` applies a result only while a fetch
  is outstanding for the week it answers, so neither a result already in the
  mailbox when its week was left nor a cancelled task's exit overwrites the
  week on screen.

  Assigns: `:week_slots` (nil before any week is asked for, then ISO date =>
  that day's slots, kept while the same week is fetched again and emptied for
  another), `:week_slots_start` (the week last asked for),
  `:week_slots_loading` and `:week_slots_error`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [cancel_async: 2, start_async: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.AvailabilityHelpers

  require Logger

  @doc "What a page starts with: no week asked for."
  @spec assign_defaults(Socket.t()) :: Socket.t()
  def assign_defaults(socket) do
    assign(socket,
      week_slots: nil,
      week_slots_start: nil,
      week_slots_loading: false,
      week_slots_error: nil
    )
  end

  @doc """
  `load_week`: fetches the week on screen, the first time a page asks.

  A week view sends it whenever it appears and on every join of the LiveView,
  so once a week has been asked for this does nothing; from then on the
  refetches keep it current.
  """
  @spec load(Socket.t()) :: Socket.t()
  def load(socket) do
    if is_nil(socket.assigns[:week_slots]), do: fetch(socket), else: socket
  end

  @doc "Fetches the week on screen again, for a page that shows one; otherwise a no-op."
  @spec refetch(Socket.t()) :: Socket.t()
  def refetch(socket) do
    if is_nil(socket.assigns[:week_slots]), do: socket, else: fetch(socket)
  end

  @doc """
  Fetches the week on screen when it is not the week last asked for, for a
  page that shows one. For the moves the page makes itself: landing the
  booker on the first free day can move the week once the grid has loaded.
  """
  @spec follow_week(Socket.t()) :: Socket.t()
  def follow_week(
        %Socket{assigns: %{week_slots: %{}, week_slots_start: week, current_week_start: week}} =
          socket
      ),
      do: socket

  def follow_week(socket), do: refetch(socket)

  @doc """
  Whether the loaded week offers `time` on `date` (an ISO 8601 date), as the
  week grid sends them; false when no week is loaded.
  """
  @spec offered?(map(), String.t(), String.t()) :: boolean()
  def offered?(assigns, date, time) do
    case assigns[:week_slots] do
      %{^date => slots} -> time in MeetingUtils.normalize_slot_list(slots)
      _no_such_day -> false
    end
  end

  @doc """
  The loaded week's days from `today` on that have a free time, in date
  order, as `%{date: Date.t(), iso: String.t(), slots: [String.t()]}`; empty
  when no week is loaded. The blocks that list times across days
  (`Blocks.NextSlots`, `Blocks.AgendaIndex`) read the week through it.
  """
  @spec free_days(map() | nil, Date.t()) :: [
          %{date: Date.t(), iso: String.t(), slots: [String.t()]}
        ]
  def free_days(nil, _today), do: []

  def free_days(week_slots, today) do
    week_slots
    |> Enum.flat_map(fn {iso, slots} ->
      with {:ok, date} <- Date.from_iso8601(iso),
           false <- Date.compare(date, today) == :lt,
           [_first | _rest] = slots <- MeetingUtils.normalize_slot_list(slots) do
        [%{date: date, iso: iso, slots: slots}]
      else
        _not_offered -> []
      end
    end)
    |> Enum.sort_by(& &1.date, Date)
  end

  @doc """
  What a block listing the week shows: `:error` when the fetch failed (the
  error wins), `:loading` when no week has been asked for yet or another
  week is on its way with its slots emptied, else `:loaded`. A refetch of the
  week shown keeps it `:loaded`. `Blocks.NextSlots` and `Blocks.AgendaIndex`
  share it, as `WeekGrid` does.
  """
  @spec view_state(map() | nil, boolean(), String.t() | nil) :: :error | :loading | :loaded
  def view_state(_week_slots, _loading, error) when is_binary(error), do: :error
  def view_state(nil, _loading, _error), do: :loading
  def view_state(week_slots, true, _error) when map_size(week_slots) == 0, do: :loading
  def view_state(_week_slots, _loading, _error), do: :loaded

  @doc """
  A `start_async/3` result. Handles `{:week_slots, week_start}`, and returns
  `:unhandled` for any other name.
  """
  @spec handle_async(term(), term(), Socket.t()) :: {:noreply, Socket.t()} | :unhandled
  def handle_async({:week_slots, week_start}, result, socket) do
    if socket.assigns[:week_slots_loading] == true and
         week_start == socket.assigns[:week_slots_start] do
      {:noreply, apply_result(socket, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(_name, _result, _socket), do: :unhandled

  defp apply_result(socket, {:ok, {:ok, week_slots}}),
    do: assign(socket, week_slots: week_slots, week_slots_loading: false, week_slots_error: nil)

  defp apply_result(socket, {:ok, {:error, reason}}), do: failed(socket, reason)
  defp apply_result(socket, {:exit, reason}), do: failed(socket, reason)

  # Says nothing about why, like the day's slot fetch: the booker can act on
  # "try again", and the reason is in the log for whoever can act on it.
  defp failed(socket, reason) do
    Logger.warning("Week slot fetch failed", reason: LogFormat.reason(reason))

    assign(socket,
      week_slots_loading: false,
      week_slots_error: dgettext("booking", "No time slots could be loaded. Please try again.")
    )
  end

  # The request, the range and the duration are built before the task, so it
  # captures plain values and never the socket.
  defp fetch(socket) do
    week_start = socket.assigns.current_week_start
    previous = socket.assigns[:week_slots_start]
    request = AvailabilityHelpers.request(socket)
    duration = AvailabilityHelpers.duration_minutes(socket)
    week_end = Date.add(week_start, 6)
    kept = if previous == week_start, do: socket.assigns[:week_slots] || %{}, else: %{}

    socket
    |> cancel_previous(previous)
    |> assign(
      week_slots: kept,
      week_slots_start: week_start,
      week_slots_loading: true,
      week_slots_error: nil
    )
    |> start_async(
      {:week_slots, week_start},
      Tasks.with_context(fn -> Offer.slots_for_range(request, week_start, week_end, duration) end)
    )
  end

  defp cancel_previous(socket, nil), do: socket
  defp cancel_previous(socket, week_start), do: cancel_async(socket, {:week_slots, week_start})
end
