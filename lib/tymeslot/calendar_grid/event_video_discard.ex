defmodule Tymeslot.CalendarGrid.EventVideoDiscard do
  @moduledoc """
  Deletes the video room a calendar grid event no longer uses: the one a video
  change replaced or removed, a new one that could not be put on the event, or
  the room of an event that was deleted.

  The delete never runs inline. It is queued on
  `Tymeslot.Workers.VideoSyncWorker`, which retries a failure and treats a
  room the provider no longer has as deleted.

  ## Which id

  A room `Tymeslot.CalendarGrid.EventVideoRooms` recorded is deleted by that
  record, which holds the id the provider gave when the room was made.

  Any other room is only known by its join link. Its id is parsed back out of
  the link only where that is exact, which is Zoom alone: the meeting id in
  `/j/<id>` is the id the delete addresses. Google Meet's link names a meeting
  code rather than the space it was created as, and the Meet API has no call
  that deletes a space anyway; Teams, MiroTalk and custom links have no room
  object to delete. Those rooms are left where they are, with an `info` line
  naming the room by `Tymeslot.Infrastructure.Logging.Redactor.fingerprint/1`
  only.

  Leaving them is also what keeps deletion no more aggressive than the
  notification an attendee gets: an attendee who still holds a replaced
  Teams or MiroTalk link can still join, as before.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Workers.VideoSyncWorker

  @typedoc """
  How the room is known: by its join link, or by the id its provider returned
  when it was made.
  """
  @type room_ref :: {:link, String.t()} | {:id, String.t()}

  @doc """
  Deletes the room `ref` names, made for `event` on the video integration
  `video_integration_id` of `user_id`, which the event no longer uses.

  A room recorded for the event on that integration is deleted by its record;
  when `ref` is an id, only the record holding that id. Otherwise the room is
  deleted by its id where that is exact (see the moduledoc).
  """
  @spec discard(pos_integer(), map(), pos_integer() | nil, room_ref() | nil) :: :ok
  def discard(user_id, event, video_integration_id, ref)
      when is_integer(video_integration_id) and is_tuple(ref) do
    case recorded(event, video_integration_id, ref) do
      [] -> discard_unrecorded(user_id, video_integration_id, ref)
      rooms -> EventVideoRooms.discard(rooms)
    end
  end

  def discard(_user_id, _event, _video_integration_id, _ref), do: :ok

  @doc """
  Deletes the room of a grid event that has just been deleted from its
  calendar, when no record holds it; the recorded ones are deleted by
  `EventVideoRooms.event_deleted/1`. Only called once the provider has deleted
  the event, never for a delete queued for the next sync, whose event is still
  on the calendar.
  """
  @spec event_deleted(pos_integer(), map()) :: :ok
  def event_deleted(
        user_id,
        %{video_integration_id: video_integration_id, video_link: link} = event
      )
      when is_integer(video_integration_id) and is_binary(link) and link != "" do
    case EventVideoRooms.rooms_on_integration(event, video_integration_id) do
      [] -> discard_unrecorded(user_id, video_integration_id, {:link, link})
      _recorded -> :ok
    end
  end

  def event_deleted(_user_id, _event), do: :ok

  defp recorded(event, video_integration_id, {:id, room_id}) do
    event
    |> EventVideoRooms.rooms_on_integration(video_integration_id)
    |> Enum.filter(&(&1.room_id == room_id))
  end

  defp recorded(event, video_integration_id, {:link, _link}),
    do: EventVideoRooms.rooms_on_integration(event, video_integration_id)

  defp discard_unrecorded(user_id, video_integration_id, {_kind, known_by} = ref) do
    room_ref = Redactor.fingerprint(known_by)

    case Video.fetch_integration_for_user(video_integration_id, user_id) do
      {:ok, %{provider: "zoom"}} ->
        enqueue(user_id, video_integration_id, zoom_room_id(ref), room_ref)

      {:ok, integration} ->
        Logger.info("Video room left in place: its provider has no room to delete by its link",
          video_integration_id: video_integration_id,
          provider: integration.provider,
          room_ref: room_ref
        )

      {:error, :not_found} ->
        :ok
    end

    :ok
  end

  defp zoom_room_id({:id, room_id}), do: room_id
  defp zoom_room_id({:link, link}), do: Video.extract_room_id(link, :zoom)

  defp enqueue(user_id, video_integration_id, room_id, room_ref)
       when is_binary(room_id) and room_id != "" do
    case VideoSyncWorker.enqueue_room_delete(user_id, video_integration_id, room_id) do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue the delete of a video room a calendar event dropped",
          video_integration_id: video_integration_id,
          room_ref: room_ref,
          reason: inspect(reason)
        )
    end
  end

  defp enqueue(_user_id, video_integration_id, _room_id, room_ref) do
    Logger.info("Video room left in place: no room id in its link",
      video_integration_id: video_integration_id,
      room_ref: room_ref
    )
  end
end
