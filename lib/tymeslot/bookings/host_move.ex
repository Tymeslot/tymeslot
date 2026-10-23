defmodule Tymeslot.Bookings.HostMove do
  @moduledoc """
  Moves a meeting the host manages (`Tymeslot.Meetings.HostManaged.managed?/1`, one
  confirmed from a poll) to a new start, keeping its length.

  The host chooses the time, as they did when they confirmed the poll, so the
  schedule the booking page offers is not consulted, nor are their booking
  limits or buffers. Two things still refuse it, as they refuse confirming
  the poll: their time off (`:time_off`), and another meeting of theirs
  overlapping that time (`:slot_taken`). Everything else follows the
  reschedule path (`Tymeslot.Bookings.Reschedule.apply_new_time/5`): the
  calendar entry and any video room move, reminders are pinned to the new
  time, and the host and every guest get the new time with an updated
  calendar entry, the guests asked again whether they can come.
  """

  alias Tymeslot.Auth
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.Bookings.{Errors, Policy, Reschedule}
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.{HostManaged, MeetingQueries, MeetingSchema}

  @doc """
  Moves the host's meeting `meeting_uid` to start at `new_start`.

  Returns `{:error, :not_managed_by_host}` for a meeting with a booker, who
  moves it themselves, `{:error, :slot_in_past}` for a time that has
  started, and `{:error, :time_off}` for a time inside the host's time off.
  """
  @spec move(String.t(), DateTime.t(), integer()) ::
          {:ok, MeetingSchema.t()}
          | {:error,
             Errors.classified_error()
             | :not_managed_by_host
             | :slot_in_past
             | :time_off}
  def move(meeting_uid, %DateTime{} = new_start, organizer_user_id)
      when is_binary(meeting_uid) and is_integer(organizer_user_id) do
    with {:ok, original} <- fetch_meeting(meeting_uid, organizer_user_id),
         :ok <- ensure_host_managed(original),
         :ok <- Policy.can_reschedule_meeting?(original),
         :ok <- ensure_future(new_start),
         new_times = host_times(original, new_start),
         :ok <- TimeOff.ensure_clear(organizer_user_id, new_times.start_time, new_times.end_time) do
      Reschedule.apply_new_time(original, new_times, nil, %{}, host_chosen: true)
    end
  end

  # As on a booker's reschedule: a host whose account waits to be deleted has
  # meetings that are about to go.
  defp fetch_meeting(meeting_uid, organizer_user_id) do
    with false <- Auth.deletion_pending?(organizer_user_id),
         {:ok, meeting} <-
           MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id) do
      {:ok, meeting}
    else
      _pending_or_not_found -> {:error, :meeting_not_found}
    end
  end

  defp ensure_host_managed(meeting) do
    if HostManaged.managed?(meeting), do: :ok, else: {:error, :not_managed_by_host}
  end

  defp ensure_future(start) do
    if DateTime.compare(start, Clock.utc_now()) == :gt, do: :ok, else: {:error, :slot_in_past}
  end

  defp host_times(meeting, new_start) do
    length = DateTime.diff(meeting.end_time, meeting.start_time, :second)
    start = DateTime.truncate(new_start, :second)

    %{
      start_time: start,
      end_time: DateTime.add(start, length, :second),
      duration_minutes: div(length, 60)
    }
  end
end
