defmodule Tymeslot.Availability.SessionSlots do
  @moduledoc """
  What a fixed-date meeting type offers (`Tymeslot.MeetingTypes.FixedDates`):
  the sessions its host planned (`Tymeslot.Meetings.PlannedSessions`) that
  are still open for registration and have a seat left, in the slot shape
  the booking page already renders for a group type,
  `%{time: label, seats_left: n, capacity: c}`.

  The type's availability schedule plays no part, and neither do the host's
  calendar and bookings: a planned session is the host's own commitment, on
  their calendar from the moment it was planned. Each session is listed
  under the date it starts on in the booker's time zone.
  """

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Meetings.Seats

  @doc "The open sessions starting on `date` in `user_timezone`."
  @spec day_slots(map(), Date.t(), String.t(), DateTime.t()) :: [map()]
  def day_slots(meeting_type, %Date{} = date, user_timezone, now \\ DateTime.utc_now()) do
    meeting_type
    |> open_sessions(user_timezone, now)
    |> Enum.filter(fn {local_start, _session, _seats_left} ->
      DateTime.to_date(local_start) == date
    end)
    |> Enum.map(fn {local_start, session, seats_left} ->
      %{
        time: TimeSlots.format_datetime_slot(local_start),
        seats_left: seats_left,
        capacity: session.capacity
      }
    end)
  end

  @doc """
  Which days in `start_date..end_date` have an open session, as the map of
  ISO 8601 dates to booleans the booking calendar reads.
  """
  @spec days(map(), Date.t(), Date.t(), String.t(), DateTime.t()) :: %{String.t() => boolean()}
  def days(meeting_type, start_date, end_date, user_timezone, now \\ DateTime.utc_now()) do
    open_days =
      meeting_type
      |> open_sessions(user_timezone, now)
      |> MapSet.new(fn {local_start, _session, _seats_left} -> DateTime.to_date(local_start) end)

    Date.range(start_date, end_date)
    |> Map.new(&{Date.to_iso8601(&1), MapSet.member?(open_days, &1)})
  end

  @doc "Whether `meeting_type` has a session anyone can still sign up for."
  @spec any_open?(map(), DateTime.t()) :: boolean()
  def any_open?(meeting_type, now \\ DateTime.utc_now()),
    do: open_sessions(meeting_type, "Etc/UTC", now) != []

  defp open_sessions(meeting_type, user_timezone, now) do
    meeting_type
    |> PlannedSessions.upcoming(now)
    |> Enum.filter(&PlannedSessions.open?(&1, now))
    |> Enum.map(&{&1, Seats.seats_left(&1, &1.capacity)})
    |> Enum.filter(fn {_session, seats_left} -> seats_left > 0 end)
    |> Enum.map(fn {session, seats_left} ->
      {DateTime.shift_zone!(session.start_time, user_timezone), session, seats_left}
    end)
  end
end
