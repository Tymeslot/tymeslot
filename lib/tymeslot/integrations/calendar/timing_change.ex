defmodule Tymeslot.Integrations.Calendar.TimingChange do
  @moduledoc """
  How a provider event's timing differs from the meeting it carries, as one
  sync pass sees it.

  A moved start is for the host to look at (`:moved`). An end that moved
  alone is the host lengthening or shortening the meeting, which the meeting
  follows (`{:end_moved, end_time}`), but only when the host's calendar
  changed it: the end has to differ both from the meeting's and from the one
  the calendar showed at the last sync that found the two in step
  (`seen_calendar_end_time`). An end that differs from the meeting's but is
  the one the calendar has shown all along was already accepted, so it is
  no change.

  A meeting with no seen end yet (one that predates the record) takes
  whatever the calendar shows as its starting point: an end the host changed
  before meetings followed such changes is left as it is, rather than being
  written over the booking and announced to its attendees as if it had just
  happened.

  An all-day event carries no hours, so only its first day is compared, on
  the host's calendar: the meeting's UTC date is the day before for a
  morning meeting east of UTC.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Meetings.MeetingSchema

  @type t :: :none | :moved | {:end_moved, DateTime.t()}

  @spec classify(MeetingSchema.t(), CalendarEvent.t(), String.t() | nil) :: t()
  def classify(meeting, %CalendarEvent{all_day: true} = cal_event, host_zone) do
    meeting_day = meeting.start_time |> DateTime.shift_zone!(host_zone) |> DateTime.to_date()

    if cal_event.start_date == meeting_day, do: :none, else: :moved
  end

  # Timed event with no start_at — should not occur for valid timed events, treat as unchanged.
  def classify(_meeting, %CalendarEvent{start_at: nil}, _host_zone), do: :none

  def classify(meeting, %CalendarEvent{start_at: start_at, end_at: end_at}, _host_zone) do
    cond do
      not same_second?(meeting.start_time, start_at) -> :moved
      is_nil(end_at) or same_second?(meeting.end_time, end_at) -> :none
      not calendar_changed_end?(meeting.seen_calendar_end_time, end_at) -> :none
      true -> {:end_moved, DateTime.truncate(end_at, :second)}
    end
  end

  @doc """
  The end a timed provider event shows, to the second, for recording as the
  meeting's seen end; nil for an all-day event or one without an end.
  """
  @spec seen_end(CalendarEvent.t()) :: DateTime.t() | nil
  def seen_end(%CalendarEvent{
        all_day: false,
        start_at: %DateTime{},
        end_at: %DateTime{} = end_at
      }),
      do: DateTime.truncate(end_at, :second)

  def seen_end(%CalendarEvent{}), do: nil

  defp calendar_changed_end?(nil, _end_at), do: false
  defp calendar_changed_end?(seen, end_at), do: not same_second?(seen, end_at)

  defp same_second?(a, b),
    do: DateTime.compare(DateTime.truncate(a, :second), DateTime.truncate(b, :second)) == :eq
end
