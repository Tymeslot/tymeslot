defmodule Tymeslot.CalendarGrid.EditGuard do
  @moduledoc """
  Whether an event may be changed from the calendar, asked the same way
  wherever it is changed from.

    * `writable/2`: the event sits on one of the organiser's own
      integrations, on a calendar that takes writes, and is not a Tymeslot
      booking (a booking is rescheduled or cancelled from the booking). The
      organiser's integrations are passed in, so a check on render needs no
      query.
    * `seat_lock/2`: no group meeting with live seats sits on it. Re-read
      from the database on every call, since a seat booked since the events
      were loaded must count.
    * `rate_limit/1`: the organiser is within the calendar edit rate limit.

  `check/3` asks those three, in that order, for a change about to be made.
  `movable?/2` (`movable/2` for many events at once) and `check_timing/3`
  add the one more a change of timing needs: the calendar copy of a booking
  keeps the booking's time, so it can be deleted from the calendar but not
  moved or resized.

    * `check_transfer/3`: a move to another calendar, which the copy of a
      booking refuses as it refuses a change of timing, under the move rate
      limit (`move_rate_limit/1`) rather than the edit one.

  `free_busy_editable?/2` says whether the organiser may change an event's
  Busy/Free: a booking, and the calendar copy of one, follow their meeting
  type's "show as free" setting, so neither may. `free_busy_change/1` is
  the same rule as a refusal, which `EventEdit.update_event/4` asks of every
  change of Busy/Free whatever the caller drew.

  `guest_update/3` says whether the organiser may email an event's guests
  (invite, remove, tell them about a change): the event is writable, and
  they organise it.
  """

  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Security.RateLimiter

  @type refusal ::
          {:error, :booking | :unauthorized | :read_only | :group_booking}
          | {:error, :rate_limited, String.t()}

  @doc "Whether `event` may be changed, for drawing the affordance; no query."
  @spec editable?([map()], map()) :: boolean()
  def editable?(integrations, event), do: writable(integrations, event) == :ok

  @doc "Whether `event` may be moved or resized, for drawing the affordance."
  @spec movable?([map()], map()) :: boolean()
  def movable?(integrations, event),
    do: editable?(integrations, event) and not EventDeletion.booking_copy?(event)

  @doc """
  Whether `event`'s Busy/Free may be changed from the calendar: a writable
  event that is neither a booking nor a booking's calendar copy, whose
  state follows the meeting type. The rule `movable?/2` asks, for another
  reason; one query for the booking copy.
  """
  @spec free_busy_editable?([map()], map()) :: boolean()
  def free_busy_editable?(integrations, event), do: movable?(integrations, event)

  @doc """
  Refuses a change of Busy/Free to a booking or to a booking's calendar
  copy, whose state follows the meeting type. One query for the copy.
  """
  @spec free_busy_change(map()) :: :ok | {:error, :booking}
  def free_busy_change(%{kind: :booking}), do: {:error, :booking}
  def free_busy_change(event), do: not_booking_copy(event)

  @doc """
  Whether the user `user_id` may tell `event`'s guests about a change: it
  sits on a writable calendar of one of `integrations` (`writable/2`), and
  they organise it (`AttendeeNotifications.organised_by?/2`). An update in
  their name about an event someone else organises would tell the real
  organiser's guests of a change that is not theirs to announce.
  """
  @spec guest_update(pos_integer(), [map()], map()) ::
          :ok | {:error, :booking | :unauthorized | :read_only | :not_organiser}
  def guest_update(user_id, integrations, event) do
    with :ok <- writable(integrations, event) do
      if AttendeeNotifications.organised_by?(event, user_id),
        do: :ok,
        else: {:error, :not_organiser}
    end
  end

  @doc """
  The events of `events` that `movable?/2` allows, for drawing a whole window:
  the booking copies among them are found in one query, not one per event.
  """
  @spec movable([map()], [map()]) :: [map()]
  def movable(integrations, events) do
    editable = Enum.filter(events, &editable?(integrations, &1))
    copies = editable |> EventDeletion.booking_copies() |> MapSet.new()

    Enum.reject(editable, &MapSet.member?(copies, &1))
  end

  @doc "Whether `event` sits on a writable calendar of one of `integrations`."
  @spec writable([map()], map()) :: :ok | {:error, :booking | :unauthorized | :read_only}
  def writable(_integrations, %{kind: :booking}), do: {:error, :booking}

  def writable(integrations, event) do
    case Enum.find(integrations, &(&1.id == Map.get(event, :calendar_integration_id))) do
      nil ->
        {:error, :unauthorized}

      integration ->
        if Selection.event_writable?(event, integration), do: :ok, else: {:error, :read_only}
    end
  end

  @doc "Refuses a change to an event a group meeting with live seats sits on."
  @spec seat_lock(pos_integer(), map()) :: :ok | {:error, :group_booking}
  def seat_lock(user_id, event) do
    if Meetings.group_booking_uid?(user_id, Map.get(event, :uid)),
      do: {:error, :group_booking},
      else: :ok
  end

  @doc "The calendar edit rate limit for `user_id`."
  @spec rate_limit(pos_integer()) :: :ok | {:error, :rate_limited, String.t()}
  def rate_limit(user_id) do
    case RateLimiter.check(:calendar_event_edit, user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  @doc "Every gate a change to `event` passes, in order."
  @spec check(pos_integer(), [map()], map()) :: :ok | refusal()
  def check(user_id, integrations, event) do
    with :ok <- writable(integrations, event),
         :ok <- seat_lock(user_id, event),
         do: rate_limit(user_id)
  end

  @doc "`check/3` for a change of timing, which the copy of a booking also refuses."
  @spec check_timing(pos_integer(), [map()], map()) :: :ok | refusal()
  def check_timing(user_id, integrations, event) do
    with :ok <- writable(integrations, event),
         :ok <- not_booking_copy(event),
         do: check(user_id, integrations, event)
  end

  @doc """
  The gates a move of `event` to another calendar passes: it is writable,
  not the copy of a booking, not held by live seats, and the organiser is
  within the move rate limit. The destination is checked by the caller
  against the calendars it offered.
  """
  @spec check_transfer(pos_integer(), [map()], map()) :: :ok | refusal()
  def check_transfer(user_id, integrations, event) do
    with :ok <- transfer_gates(user_id, integrations, event), do: move_rate_limit(user_id)
  end

  @doc """
  `check_transfer/3` without the rate limit, which counts a move: for a
  caller that may still ask the organiser before moving, and counts the
  move once it goes ahead.
  """
  @spec transfer_gates(pos_integer(), [map()], map()) :: :ok | refusal()
  def transfer_gates(user_id, integrations, event) do
    with :ok <- writable(integrations, event),
         :ok <- not_booking_copy(event),
         do: seat_lock(user_id, event)
  end

  @doc "The calendar move rate limit for `user_id`."
  @spec move_rate_limit(pos_integer()) :: :ok | {:error, :rate_limited, String.t()}
  def move_rate_limit(user_id) do
    case RateLimiter.check(:calendar_event_move, user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  defp not_booking_copy(event),
    do: if(EventDeletion.booking_copy?(event), do: {:error, :booking}, else: :ok)
end
