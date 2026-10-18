defmodule Tymeslot.CalendarGrid.EditGuard do
  @moduledoc """
  Whether an event may be changed from the calendar, asked the same way by
  both calendar surfaces.

    * `writable/2`: the event sits on one of the organiser's own
      integrations, on a calendar that takes writes, and is not a Tymeslot
      booking (a booking is rescheduled or cancelled from the booking). The
      organiser's integrations are passed in, so a check on render needs no
      query.
    * `seat_lock/2`: no group meeting with live seats sits on it. Re-read
      from the database on every call, since a seat booked since the events
      were loaded must count.
    * `rate_limit/1`: the organiser is within the calendar edit rate limit.

  `check/3` asks all three, in that order, for a change about to be made.
  `movable?/2` and `check_timing/3` add the one more a change of timing
  needs: the calendar copy of a booking keeps the booking's time, so it can
  be deleted from the calendar but not moved or resized.
  """

  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.Integrations.Calendar.Selection
  alias Tymeslot.Meetings
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

  defp not_booking_copy(event),
    do: if(EventDeletion.booking_copy?(event), do: {:error, :booking}, else: :ok)
end
