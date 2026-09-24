defmodule Tymeslot.Bookings.RescheduleLocation do
  @moduledoc """
  Where a rescheduled meeting is held, when the booker picks somewhere new.

  A meeting type offering several locations lets the booker choose one when
  booking, and the reschedule form offers the same choice again, opened on the
  location the meeting already has. Most reschedules leave it alone, and then
  this module changes nothing.

  ## Changing the location is not just a column update

  The location decides whether the meeting has a provider-side video room, and
  on which integration. So a change is resolved in two halves:

    * `attributes/3` is the write. It returns the location fields to merge
      into the reschedule's update, and, whenever the new location is not on
      the integration that owns the current room, blanks every room field in
      the same write. The meeting then never advertises a join link for a
      place it is no longer held, even for the moment before the provider
      catches up.

    * `release_abandoned_room/2` and `create_room/2` are the provider side,
      run after the write commits. They read the change off the meeting's
      before and after states rather than being told about it, so they cannot
      disagree with what was actually persisted.

  In both directions the rule is the same: the old room is deleted
  (`Tymeslot.Workers.VideoSyncWorker.release/1`), and a room is created on the
  new integration where there is one (`Tymeslot.Workers.VideoRoomWorker`).
  Moving between two options on the *same* integration keeps the room, whose
  times the ordinary reschedule sync already moves.

  A new room also takes over the reschedule's announcement, exactly as a new
  booking's room takes over its confirmation: the email is the attendee's one
  message about the move, and sent before the room exists it would carry no
  join link.

  ## The booker submits an id, never a location

  As on a new booking, everything the choice means is re-derived from the
  host's own meeting type (`MeetingTypes.resolve_location/3`). Unlike a new
  booking, an id the meeting type does not offer is ignored rather than
  resolved to the first option: a reschedule already has a location, and a
  stale or forged id must not move it anywhere.
  """

  require Logger

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Workers.{VideoRoomWorker, VideoSyncWorker}

  # Everything `Tymeslot.Meetings.VideoRooms` writes when it attaches a room,
  # bar the Teams uid rewrite: the uid is the meeting's calendar identity from
  # then on, and must survive the room.
  @detached_room %{
    meeting_url: nil,
    video_room_id: nil,
    video_provider: nil,
    organizer_video_url: nil,
    attendee_video_url: nil,
    video_room_enabled: false,
    video_room_created_at: nil,
    video_room_expires_at: nil
  }

  @doc """
  The location attributes a reschedule writes, or `%{}` when it keeps the
  meeting where it is.

  `params` carries the booker's `:location_option_id` and, for a phone option
  that asks for it, `:location_phone`, or for a video option offering several
  providers, `:location_video_integration_id`. An ad-hoc meeting (no
  `meeting_type_id`) never changes location: the meeting type a reschedule
  resolves for it is matched by duration, and its locations were never the
  ones this meeting was booked against.
  """
  @spec attributes(Meeting.t(), map() | nil, map()) :: map()
  def attributes(%Meeting{meeting_type_id: nil}, _meeting_type, _params), do: %{}
  def attributes(%Meeting{}, nil, _params), do: %{}

  def attributes(%Meeting{} = meeting, meeting_type, params) do
    case chosen(meeting_type, params) do
      nil -> %{}
      resolution -> changes(meeting, resolution)
    end
  end

  @doc """
  Enqueues deletion of the provider room a reschedule detached, if it did.
  """
  @spec release_abandoned_room(Meeting.t(), Meeting.t()) :: :ok
  def release_abandoned_room(%Meeting{video_room_id: room_id}, %Meeting{video_room_id: room_id}),
    do: :ok

  def release_abandoned_room(%Meeting{}, %Meeting{video_room_id: nil}), do: :ok

  def release_abandoned_room(%Meeting{}, %Meeting{video_room_id: room_id} = original) do
    case VideoSyncWorker.release(original) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue release of a video room left behind by a reschedule",
          meeting_id: original.id,
          provider: original.video_provider,
          video_room_id: room_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Schedules a room for a confirmed meeting that a reschedule moved onto a new
  video integration, handing it the reschedule's announcement.

  Returns `:scheduled` when the room's job now owns the announcement, and
  `:not_scheduled` when the caller still has to send it.

  Only a confirmed meeting gets one here. A booking still held for approval,
  or not yet paid for, is given its room by the path that confirms it, exactly
  as a new booking is.
  """
  @spec create_room(Meeting.t(), Meeting.t()) :: :scheduled | :not_scheduled
  def create_room(
        %Meeting{status: "confirmed", video_room_id: nil, video_integration_id: new_id} = updated,
        %Meeting{video_integration_id: old_id} = original
      )
      when is_integer(new_id) and new_id != old_id do
    case VideoRoomWorker.schedule_video_room_creation_with_reschedule_announcement(
           updated,
           original
         ) do
      :ok ->
        :scheduled

      {:error, reason} ->
        # `VideoRoomRecoveryScanWorker` finds confirmed meetings missing the
        # room their integration promises, so the room is a delay, not a loss.
        # The announcement cannot wait for that sweep.
        Logger.warning("Failed to schedule a video room for a rescheduled meeting",
          meeting_id: updated.id,
          reason: inspect(reason)
        )

        :not_scheduled
    end
  end

  def create_room(%Meeting{}, %Meeting{}), do: :not_scheduled

  defp chosen(meeting_type, %{location_option_id: option_id} = params)
       when is_binary(option_id) do
    if Enum.any?(MeetingTypes.location_options(meeting_type), &(&1.id == option_id)) do
      MeetingTypes.resolve_location(
        meeting_type,
        option_id,
        Map.get(params, :location_phone),
        Map.get(params, :location_video_integration_id)
      )
    end
  end

  defp chosen(_meeting_type, _params), do: nil

  # The same option with the same number, on the same provider, is the booker
  # leaving the picker where it opened. Rewriting it would still not be a
  # no-op: a video meeting's `location` holds its join URL, which re-resolving
  # would replace with the option's label. A different provider within the
  # same option is a move, and falls through to the clauses below.
  defp changes(
         %Meeting{location_option_id: id, attendee_phone: phone, video_integration_id: video_id},
         %{location_option_id: id, attendee_phone: phone, video_integration_id: video_id}
       ),
       do: %{}

  # A different option on the integration that already owns the room: the
  # room serves the new option as well as it served the old one.
  defp changes(
         %Meeting{video_integration_id: id} = meeting,
         %{video_integration_id: id} = resolution
       )
       when is_integer(id) do
    if meeting.video_room_id, do: Map.delete(resolution, :location), else: resolution
  end

  defp changes(%Meeting{}, resolution), do: Map.merge(resolution, @detached_room)
end
