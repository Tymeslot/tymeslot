defmodule TymeslotWeb.Themes.Shared.Journey.Facts.Slot do
  @moduledoc """
  The slot: the day and the time the booking is for.

  Owns the calendar's events (day and time picks, the hour grouping, month
  and week navigation, a week view's week and its one-click slot) and what
  showing a moment that collects it sets up: the meeting type the URL names,
  the calendar's opening day and month, the month's availability, a fresh
  slot list when the duration changed while away, and the week on screen.
  Known once a day and a time are chosen; moving on needs both.
  """

  use TymeslotWeb.Themes.Shared.Journey.Fact

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Tymeslot.Availability.Calculate
  alias TymeslotWeb.Components.MeetingUtils
  alias TymeslotWeb.Live.Scheduling.{AvailabilityHelpers, CalendarHelpers, WeekSlots}
  alias TymeslotWeb.Live.Scheduling.Handlers.SlotFetchingHandlerComponent
  alias TymeslotWeb.Themes.Shared.Journey.Fact
  alias TymeslotWeb.Themes.Shared.LiveHelpers.StepEntry
  alias TymeslotWeb.Themes.Shared.SlotGrouping

  @events [
    :select_date,
    :select_time,
    :toggle_hour,
    :prev_week,
    :next_week,
    :load_week,
    :select_slot,
    :first_available_week,
    :prev_month,
    :next_month
  ]

  @impl Fact
  def key, do: :slot

  @impl Fact
  def requires(_assigns), do: [:meeting_type]

  @impl Fact
  def required?(_assigns), do: true

  @impl Fact
  def known?(assigns), do: selection(assigns) == :ok

  @impl Fact
  def events, do: @events

  @impl Fact
  def handle(socket, :select_date, date), do: select_date(socket, date)

  def handle(socket, :select_time, time) do
    new_time = if socket.assigns[:selected_time] == time, do: nil, else: time
    {:noreply, assign(socket, :selected_time, new_time)}
  end

  def handle(socket, :toggle_hour, hour), do: toggle_hour(socket, hour)

  def handle(socket, :prev_week, _data),
    do: {:noreply, socket |> CalendarHelpers.handle_week_navigation(:prev) |> WeekSlots.refetch()}

  def handle(socket, :next_week, _data),
    do: {:noreply, socket |> CalendarHelpers.handle_week_navigation(:next) |> WeekSlots.refetch()}

  # A week view asking for its week; see `WeekSlots.load/1`.
  def handle(socket, :load_week, _data), do: {:noreply, WeekSlots.load(socket)}

  def handle(socket, :select_slot, {date, time}) when is_binary(date) and is_binary(time),
    do: select_slot(socket, date, time)

  def handle(socket, :select_slot, _data), do: {:noreply, socket}

  # Back to the week the page landed the booker on; the week view follows.
  def handle(socket, :first_available_week, _data),
    do: {:noreply, socket |> CalendarHelpers.return_to_landing() |> WeekSlots.follow_week()}

  def handle(socket, :prev_month, _data),
    do: {:noreply, CalendarHelpers.handle_month_navigation(socket, :prev)}

  def handle(socket, :next_month, _data),
    do: {:noreply, CalendarHelpers.handle_month_navigation(socket, :next)}

  # Every arrival at the step fetches a week view's week again: the duration
  # can have changed on the overview, and a booking that lost its slot comes
  # back here. A no-op for a page that shows no week.
  @impl Fact
  def enter(socket, params) do
    socket
    |> StepEntry.handle_schedule_entry(params)
    |> refresh_stale_slot_snapshot()
    |> WeekSlots.refetch()
  end

  @impl Fact
  def continue(socket) do
    case selection(socket.assigns) do
      :ok -> {:done, socket}
      {:error, reason} -> {:error, reason}
    end
  end

  defp selection(assigns),
    do:
      Calculate.validate_time_selection(
        assigns[:selected_date],
        assigns[:selected_time],
        assigns[:available_slots]
      )

  # Defensive on the nil date: neither theme's day button deselects any
  # more, so nothing reaches here with nil today. The guard stays because
  # sending {:load_slots, nil} would fetch slots for no day at all.
  #
  # Resets `:expanded_hour` here, at the point the booker actively picks
  # a date, rather than in the fetch that follows: the fetch also runs
  # for refetches the booker did not cause a date change with (a
  # timezone change, a lost-slot retry), which must not spring a
  # deliberately collapsed `:none` back open.
  defp select_date(socket, date) do
    socket =
      assign(socket,
        selected_date: date,
        selected_time: nil,
        expanded_hour: nil,
        loading_slots: date != nil,
        calendar_error: nil
      )

    if date, do: send(self(), {:load_slots, date})
    {:noreply, socket}
  end

  # The week grid's one click: a day and a time together. Unlike
  # `select_date/2` it keeps the time, and unlike `:select_time` a second click
  # never unchooses it. A new day's slots are loaded as a day pick loads them,
  # so the booking step and a reschedule see the state a day and a time click
  # leave. The payload is visitor input, so a pair the loaded week does not
  # offer is ignored; the submit would refuse it anyway. So is every pair
  # while the week is being fetched again: the map kept on screen then may
  # predate the change that caused the fetch (a timezone switch), and a time
  # picked from it would be read in the new zone.
  defp select_slot(socket, date, time) do
    cond do
      socket.assigns[:week_slots_loading] ->
        {:noreply, socket}

      not WeekSlots.offered?(socket.assigns, date, time) ->
        {:noreply, socket}

      socket.assigns[:selected_date] == date ->
        {:noreply, assign(socket, :selected_time, time)}

      true ->
        socket = assign(socket, selected_date: date, selected_time: time, expanded_hour: nil)
        {:ok, socket} = SlotFetchingHandlerComponent.load_slots(socket, date)
        {:noreply, socket}
    end
  end

  # `expanded_hour` holds three states, not two: nil means "not chosen, so
  # open the earliest hour", an integer means that hour, and :none means the
  # booker closed it and it must stay closed until they choose again.
  #
  # `hour` is guarded to a binary because event payloads for non-"form"
  # events reach `handle_event/3` verbatim from client JSON with no type
  # coercion: a crafted socket push can deliver a list or map here, which
  # `Integer.parse/1` has no clause for. A non-binary payload is ignored,
  # leaving state untouched, the same way an unparsable string already is.
  defp toggle_hour(socket, hour) when is_binary(hour) do
    grouping =
      SlotGrouping.group(
        MeetingUtils.normalize_slot_list(socket.assigns[:available_slots] || []),
        socket.assigns[:slot_interval_minutes],
        socket.assigns[:duration_minutes]
      )

    current = SlotGrouping.effective_expanded_hour(socket.assigns[:expanded_hour], grouping)

    next =
      case Integer.parse(hour) do
        {^current, ""} -> :none
        {requested, ""} -> requested
        _unparsable -> socket.assigns[:expanded_hour]
      end

    {:noreply, assign(socket, :expanded_hour, next)}
  end

  defp toggle_hour(socket, _hour), do: {:noreply, socket}

  # `:available_slots`, `:duration_minutes`, `:slot_interval_minutes` and
  # `:expanded_hour` are snapshotted by `SlotFetchingHandlerComponent` at
  # fetch time and do not track a meeting-type/duration change made while
  # away from this step (e.g. back to :overview, pick a different
  # duration, forward again). Only compare against a snapshot that
  # actually exists (`:duration_minutes` non-nil): the very first entry
  # into :schedule has no snapshot yet and nothing stale to refresh.
  defp refresh_stale_slot_snapshot(socket) do
    case socket.assigns[:duration_minutes] do
      nil ->
        socket

      snapshot_duration ->
        current_duration = AvailabilityHelpers.duration_minutes(socket)
        current_interval = AvailabilityHelpers.slot_interval_minutes(socket)

        if snapshot_duration == current_duration and
             socket.assigns[:slot_interval_minutes] == current_interval do
          socket
        else
          socket
          |> assign(
            available_slots: [],
            selected_time: nil,
            expanded_hour: nil,
            duration_minutes: nil,
            slot_interval_minutes: nil
          )
          |> then(fn socket ->
            {:ok, socket} = SlotFetchingHandlerComponent.maybe_reload_slots(socket)
            socket
          end)
        end
    end
  end
end
