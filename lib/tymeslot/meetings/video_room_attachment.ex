defmodule Tymeslot.Meetings.VideoRoomAttachment do
  @moduledoc """
  Attaches a video room the provider has already created to its meeting.

  The last step of `Tymeslot.Meetings.VideoRooms.add_video_room_to_meeting/1`,
  and the only one inside a database transaction: the provider call happens
  before it, so a slow provider never holds a connection. The meeting row is
  re-locked and re-checked here, so a concurrent worker that attached a room
  first wins and this one's room is discarded, and a room created for a
  location the meeting has since left is released instead of attached.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Meetings.{MeetingQueries, MeetingSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @doc """
  Writes `video_room_attrs` onto `meeting` under the row lock, then schedules
  the calendar update that carries the join link into the calendar event.

  Returns `{:ok, meeting}` when the room was attached, or when it was not
  because another writer attached one first or the meeting moved to another
  location (its room is then released); `{:error, :calendar_event_pending}`
  when the room was placed on a booking calendar event the meeting has since
  left; `{:error, reason}` when the write failed.
  """
  # The room was created for the integration `meeting` named when it was read,
  # before the provider call. A reschedule can move the meeting to another
  # location while that call is in flight, and attaching the room anyway would
  # hand an in-person meeting a join link. So the integration is re-checked
  # under the lock too, and a room created for a location the meeting has left
  # is released rather than attached.
  #
  # A Teams meeting placed on the booking's own calendar event (see
  # `Tymeslot.Integrations.MeetingProvisioning.teams_room_placement/1`) is
  # that event, so its room id is the event id the meeting was read with. The
  # calendar queue can replace that event meanwhile
  # (`Tymeslot.Meetings.CalendarEventSync.replace/3`), and the room would then
  # be recorded on an event that is gone. So the event is re-checked under the
  # lock as well, and a room placed on an event the meeting has left is not
  # attached: the job waits and places it again on the event the meeting now
  # has. The online meeting goes with the event it was put on.
  @spec persist(MeetingSchema.t(), map()) ::
          {:ok, MeetingSchema.t()} | {:error, term()}
  def persist(%MeetingSchema{} = meeting, video_room_attrs) do
    transaction_result =
      Repo.transaction(fn ->
        case MeetingQueries.get_meeting_for_update(meeting.id) do
          {:ok, locked_meeting} ->
            attach_to_locked(locked_meeting, meeting, video_room_attrs)

          {:error, :not_found} ->
            Repo.rollback(:meeting_not_found)
        end
      end)

    case transaction_result do
      {:ok, {:attached, updated_meeting}} ->
        # Schedule the calendar update only once we have definitively attached the
        # video room in this call path.
        schedule_calendar_update(updated_meeting)
        {:ok, updated_meeting}

      {:ok, {:location_changed, moved_meeting}} ->
        Logger.info("Meeting changed location while its video room was created; releasing it",
          meeting_id: moved_meeting.id
        )

        release_unattached_room(meeting, video_room_attrs)
        {:ok, moved_meeting}

      {:ok, {:calendar_event_replaced, replaced_meeting}} ->
        Logger.info(
          "Booking's calendar event was replaced while its video room was placed on it; placing it again",
          meeting_id: replaced_meeting.id
        )

        {:error, :calendar_event_pending}

      {:ok, {:already_attached, existing_meeting}} ->
        Logger.info(
          "Video room already attached by a concurrent writer; discarding provider response",
          meeting_id: existing_meeting.id
        )

        {:ok, existing_meeting}

      {:error, reason} = error ->
        # The one place a room id is logged in the clear, deliberately. The
        # write that would have recorded it failed, so the room exists on the
        # provider and nothing in the database points at it: without the id and
        # URL here there is no way to find it again and delete it. Everywhere
        # else the row is reachable by `meeting_id` and the logs carry
        # `room_ref` instead.
        Logger.error("Failed to persist video room attachment",
          meeting_id: meeting.id,
          reason: inspect(reason),
          orphaned_video_room_id: Map.get(video_room_attrs, :video_room_id),
          orphaned_meeting_url: Map.get(video_room_attrs, :meeting_url)
        )

        error
    end
  end

  defp schedule_calendar_update(meeting) do
    case CalendarEventScheduler.schedule_calendar_update(meeting.id) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule calendar update after video room attachment",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )
    end
  end

  defp attach_to_locked(
         %MeetingSchema{video_room_id: nil, video_integration_id: integration_id} = locked_meeting,
         %MeetingSchema{video_integration_id: integration_id} = meeting,
         video_room_attrs
       ) do
    if left_booking_event?(locked_meeting, meeting, video_room_attrs) do
      {:calendar_event_replaced, locked_meeting}
    else
      case update_meeting_with_video_room(locked_meeting, video_room_attrs) do
        {:ok, updated_meeting} -> {:attached, updated_meeting}
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp attach_to_locked(%MeetingSchema{video_room_id: nil} = moved_meeting, _meeting, _attrs),
    do: {:location_changed, moved_meeting}

  # Another worker won the race; keep the existing attachment.
  defp attach_to_locked(%MeetingSchema{} = already_attached, _meeting, _attrs),
    do: {:already_attached, already_attached}

  # Whether the room was placed on the booking's calendar event as `meeting`
  # was read, and the locked meeting is on another event now.
  defp left_booking_event?(
         %MeetingSchema{provider_event_id: event_id},
         %MeetingSchema{provider_event_id: event_id},
         _attrs
       ),
       do: false

  defp left_booking_event?(_locked_meeting, %MeetingSchema{provider_event_id: event_id}, %{
         video_room_id: event_id
       })
       when is_binary(event_id),
       do: true

  defp left_booking_event?(_locked_meeting, _meeting, _attrs), do: false

  defp release_unattached_room(meeting, %{video_room_id: room_id} = video_room_attrs)
       when is_binary(room_id) do
    room = %{meeting | video_room_id: room_id, video_provider: video_room_attrs.video_provider}

    case VideoSyncWorker.release(room) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue release of an unattached video room",
          meeting_id: meeting.id,
          orphaned_video_room_id: room_id,
          reason: inspect(reason)
        )
    end
  end

  # A provider with no room id (a static custom link) has nothing to delete.
  defp release_unattached_room(_meeting, _video_room_attrs), do: :ok

  @spec update_meeting_with_video_room(MeetingSchema.t(), map()) ::
          {:ok, MeetingSchema.t()} | {:error, :database_update_failed}
  defp update_meeting_with_video_room(meeting, video_room_attrs) do
    case MeetingQueries.update_meeting(meeting, video_room_attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Video room added successfully",
          meeting_id: meeting.id,
          room_ref: Redactor.fingerprint(video_room_attrs.video_room_id)
        )

        {:ok, updated_meeting}

      {:error, changeset} ->
        Logger.error("Failed to update meeting with video room",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, :database_update_failed}
    end
  end
end
