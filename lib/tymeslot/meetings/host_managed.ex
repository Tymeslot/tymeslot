defmodule Tymeslot.Meetings.HostManaged do
  @moduledoc """
  Whether only the host manages a meeting, read off the meeting row. Kept
  apart from `Tymeslot.Meetings.MeetingSchema`, which holds the row's shape
  and its changesets.
  """

  @doc """
  Whether only the host manages the meeting: one confirmed from a poll. Its
  attendee is a guest like everyone else, so they are sent no booking emails
  and the public cancel and reschedule pages refuse it; the host moves it
  from the dashboard instead (`Tymeslot.Bookings.HostMove.move/3`).
  """
  @spec managed_by_host?(map()) :: boolean()
  def managed_by_host?(%{managed_by_host: true}), do: true
  def managed_by_host?(_meeting), do: false
end
