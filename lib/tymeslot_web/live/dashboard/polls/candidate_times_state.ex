defmodule TymeslotWeb.Dashboard.Polls.CandidateTimesState do
  @moduledoc """
  `PollForm`'s candidate-time rows on its socket, and the checks that follow
  them: adding and removing a row, the week grid's free and busy times
  (`Tymeslot.Polls.HostAvailability`), and the warnings for a row inside the
  host's time off or clashing with an event in their calendar
  (`SlotWarnings`).

  The calendar and availability reads run off the LiveView process with
  `start_async/3` on the socket given, as `:calendar_conflicts` and
  `:host_availability`, so their results arrive in `PollForm.handle_async/3`.
  `CandidateTimes` keeps the rows as plain data and `CandidateTimesField`
  draws them.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [start_async: 3]

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Polls.{HostAvailability, PollSchema}

  alias TymeslotWeb.Dashboard.Polls.{
    AvailabilityWeek,
    CandidateTimes,
    PollDuration,
    PollFormErrors,
    SlotWarnings
  }

  @doc "Adds a row holding `value`, or the too-many error once the poll is at its limit."
  @spec append(Socket.t(), String.t()) :: Socket.t()
  def append(socket, value) do
    if length(socket.assigns.slots) >= PollSchema.max_slots() do
      assign(
        socket,
        :errors,
        Map.put(socket.assigns.errors, :slots, [PollFormErrors.too_many_message()])
      )
    else
      {slots, counter} =
        CandidateTimes.add(socket.assigns.slots, socket.assigns.slot_counter, value)

      assign(socket,
        slots: slots,
        slot_counter: counter,
        errors: Map.delete(socket.assigns.errors, :slots)
      )
    end
  end

  @doc "Removes the row keyed `key`, with its warnings; an unknown key changes nothing."
  @spec remove(Socket.t(), String.t()) :: Socket.t()
  def remove(socket, key) do
    case CandidateTimes.remove(socket.assigns.slots, key) do
      {:ok, slots, key} ->
        socket
        |> assign(
          slots: slots,
          time_off_keys: MapSet.delete(socket.assigns.time_off_keys, key),
          conflict_keys: MapSet.delete(socket.assigns.conflict_keys, key),
          errors: Map.delete(socket.assigns.errors, :slots)
        )
        |> check_calendar()

      :error ->
        socket
    end
  end

  @doc """
  The grid's week and the host's busy time and hours for it, read again
  only when that week or the timezone changes.
  """
  @spec refresh_availability(Socket.t()) :: Socket.t()
  def refresh_availability(socket) do
    %{week_offset: offset, timezone: timezone, current_user: user} = socket.assigns
    {first_day, {from, to} = window} = AvailabilityWeek.week(timezone, offset)
    socket = assign(socket, :first_day, first_day)

    if window == socket.assigns.availability_window do
      socket
    else
      socket
      |> assign(availability_window: window, availability: :loading)
      |> start_async(
        :host_availability,
        Tasks.with_context(fn -> HostAvailability.for_window(user.id, from, to) end)
      )
    end
  end

  @doc """
  Asks the host's calendar which rows clash with an event, off the LiveView
  process, whenever the times the rows name change (their time, timezone or
  duration). A newer check replaces one still running.
  """
  @spec check_calendar(Socket.t()) :: Socket.t()
  def check_calendar(socket) do
    ranges = slot_ranges(socket.assigns)

    cond do
      ranges == socket.assigns.checked_ranges ->
        socket

      ranges == [] ->
        assign(socket, checked_ranges: [], conflict_keys: MapSet.new())

      true ->
        user_id = socket.assigns.current_user.id
        draft_id = socket.assigns.draft && socket.assigns.draft.id

        socket
        |> assign(:checked_ranges, ranges)
        |> start_async(
          :calendar_conflicts,
          Tasks.with_context(fn -> SlotWarnings.conflict_keys(user_id, draft_id, ranges) end)
        )
    end
  end

  @doc "The rows inside the host's time off, recomputed on every change for the same reasons."
  @spec assign_time_off_keys(Socket.t()) :: Socket.t()
  def assign_time_off_keys(socket) do
    keys = SlotWarnings.time_off_keys(socket.assigns.current_user.id, slot_ranges(socket.assigns))
    assign(socket, :time_off_keys, keys)
  end

  # The rows read as times, for the warnings under them.
  defp slot_ranges(%{slots: slots, timezone: timezone, duration: duration}),
    do: SlotWarnings.ranges(slots, timezone, PollDuration.parse(duration))
end
