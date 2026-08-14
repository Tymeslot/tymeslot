defmodule Tymeslot.CalendarGrid.BookingEvents do
  @moduledoc """
  Loads the organiser's bookings for a grid window as `BookingEvent` structs.

  This is the calendar grid's native view of Tymeslot bookings: it reads
  through the `Meetings` context and projects each live booking into the
  grid's event shape. Deduplication against provider-synced copies of the
  same bookings happens here so callers get a list that can be concatenated
  onto the cached provider events directly.
  """

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.Meetings

  @doc """
  Returns the user's live bookings overlapping `[start_dt, end_dt)` as
  `BookingEvent` structs, excluding any whose synced provider copy is already
  present.

  `synced_event_ids` is the set of `provider_event_id`s among the cached
  provider events loaded for the same window. A booking that has been written
  back to a connected calendar reappears in the cache as a
  `created_by_tymeslot` event; that copy stays the interactive one on the
  grid, so the booking projection is dropped to avoid a duplicate block.
  """
  @spec list_for_range(pos_integer(), DateTime.t(), DateTime.t(), MapSet.t()) :: [
          BookingEvent.t()
        ]
  def list_for_range(user_id, start_dt, end_dt, synced_event_ids \\ MapSet.new()) do
    user_id
    |> Meetings.list_meetings_in_range_for_organizer(start_dt, end_dt)
    |> Enum.reject(&synced?(&1, synced_event_ids))
    |> Enum.map(&to_event/1)
  end

  defp synced?(%{provider_event_id: nil}, _synced_event_ids), do: false

  defp synced?(%{provider_event_id: provider_event_id}, synced_event_ids),
    do: MapSet.member?(synced_event_ids, provider_event_id)

  defp to_event(meeting) do
    %BookingEvent{
      id: "booking-#{meeting.id}",
      meeting_id: meeting.id,
      uid: meeting.uid,
      summary: presence(meeting.title) || "Meeting",
      location: presence(meeting.location),
      start_at: meeting.start_time,
      end_at: meeting.end_time,
      attendee_name: presence(meeting.attendee_name),
      attendee_email: presence(meeting.attendee_email),
      join_url: presence(meeting.organizer_video_url) || presence(meeting.meeting_url),
      provider_event_id: meeting.provider_event_id,
      status: meeting.status
    }
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
