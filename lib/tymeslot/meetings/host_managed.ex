defmodule Tymeslot.Meetings.HostManaged do
  @moduledoc """
  Meetings only their host manages: those confirmed from a poll
  (`meetings.managed_by_host`). Such a meeting has no booker. Its attendee is
  a guest like everyone else, so they are sent no booking emails and the
  public cancel and reschedule pages refuse it; the host moves it from the
  dashboard instead (`Tymeslot.Bookings.HostMove.move/3`).

  Split out of `MeetingSchema` to keep it inside the size limit; the schema
  delegates `managed_by_host?/1` here.
  """

  @doc "Whether only the host manages `meeting`."
  @spec managed?(map()) :: boolean()
  def managed?(%{managed_by_host: true}), do: true
  def managed?(_meeting), do: false
end
