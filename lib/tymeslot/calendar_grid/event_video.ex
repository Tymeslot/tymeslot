defmodule Tymeslot.CalendarGrid.EventVideo do
  @moduledoc """
  Changing the video room of an existing calendar-grid event: provisioning a
  room on the chosen video integration, or removing the link altogether.

  ## Where the link lives

  One link is published, since a calendar event's description is one piece of
  text everybody it reaches shares. `join_link/2` is what that link is: the
  room's own URL on every provider whose links are plain addresses, and on
  one whose links carry a credential the room URL with a token naming nobody.

  It is written in two places, as when an event is created from the grid
  (`Tymeslot.CalendarGrid.EventCreation`):

    * on the provider event, as a "Join video call" line in the description,
      so the organiser's calendar and its attendees see it. The line for the
      previous link is replaced rather than left behind. The write goes
      through `Tymeslot.CalendarGrid.EventEdit`, so the whole event is sent
      and a failed write is queued for retry like any other edit;
    * on the cached row, as `video_link` and `video_integration_id`. Inbound
      syncs never carry these two columns, so they are written with the
      targeted local edit rather than the sync's full-row upsert, which would
      silently ignore them.

  ## Rooms

  A room that is no longer referenced (the one just replaced or removed, or a
  new one whose provider returned no join URL) is deleted on the provider on a
  best-effort basis. Cached rows do not keep the provider's room id, so it is
  parsed back out of the join URL by the rules of the provider the event's
  video integration names; providers with no room object to delete treat the
  call as a no-op.
  """

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.EventDetails

  require Logger

  @join_line_prefix "Join video call: "

  @doc """
  Gives `event` a room on the video integration `video_integration_id`, or
  removes its video link when that is `nil`.

  Returns `{:ok, url}` with the new join URL (`nil` after a removal), or:

    * `{:ok, :unchanged}` when the choice is the one the event already has:
      the integration it already holds a link from, or "None" on an event
      with no video. An integration with no link is not a no-op, since that
      is how an organiser provisions a room after a failed earlier attempt;
    * `{:error, :not_found}` when the video integration is not the organiser's;
    * `{:error, :missing_meeting_url}` when the provider created a room but
      returned no join URL, in which case the event keeps its current link;
    * `{:error, {:configuration_error, code}}` when the provider's own server
      refuses to create rooms, which
      `Tymeslot.Integrations.Video.RoomCreationError` puts into words for the
      organiser;
    * `{:error, reason}` when the room could not be created or the calendar
      rejected the change. Nothing is changed.
  """
  @spec change_event_video(pos_integer(), map(), pos_integer() | nil) ::
          {:ok, String.t() | nil | :unchanged}
          | {:error, :missing_meeting_url | :not_found | term()}
  def change_event_video(_user_id, %{video_integration_id: id, video_link: link}, id)
      when is_integer(id) and is_binary(link),
      do: {:ok, :unchanged}

  def change_event_video(_user_id, %{video_integration_id: nil, video_link: nil}, nil),
    do: {:ok, :unchanged}

  def change_event_video(user_id, event, nil) do
    with :ok <- write_description(user_id, event, nil),
         :ok <- cache_link(event, nil, nil) do
      discard_room(user_id, event.video_integration_id, event.video_link)
      {:ok, nil}
    end
  end

  def change_event_video(user_id, event, video_integration_id)
      when is_integer(video_integration_id) do
    with {:ok, _integration} <- Video.fetch_integration_for_user(video_integration_id, user_id),
         {:ok, url} <- create_room(user_id, event, video_integration_id),
         :ok <- write_new_description(user_id, event, video_integration_id, url),
         :ok <- cache_link(event, video_integration_id, url) do
      discard_room(user_id, event.video_integration_id, event.video_link)
      {:ok, url}
    end
  end

  @doc """
  The link to publish for a room just created for a grid event: the one that
  goes in the event's description, the cached `video_link`, and the invitees'
  notification.

  Unlike a booking, a grid event mints no per-participant link at all — the
  description is one piece of text every reader of the event shares — so the
  link asked for here is the identity-free one,
  `Tymeslot.Integrations.Video.Providers.ProviderBehaviour.shared_join_url/2`.
  On every provider whose join links are plain room addresses that is the
  room URL, unchanged. On one whose links carry a credential it is the room
  URL with a token that names nobody and confers no moderator rights, which
  is the only link a server enforcing tokens admits: the bare URL it refuses,
  organiser included.

  `start_at` dates the token, and anything that is not a `DateTime` (an
  all-day event's `Date`, or nothing at all) leaves the provider to date it
  from now. A recurring event's token is dated from the series' first
  occurrence, and an event moved later is not relinked, so on a token
  provider both outlive their link; on such a server the bare URL they would
  otherwise carry works no better.

  Falls back to the room's own URL whenever no link comes back, which is what
  the provider itself does when minting fails.
  """
  @spec join_link(map(), term()) :: String.t() | nil
  def join_link(%{room_data: %{meeting_url: room_url}} = meeting_context, start_at) do
    case Video.shared_join_url(meeting_context, token_time(start_at)) do
      {:ok, url} when is_binary(url) and url != "" -> url
      _unavailable -> room_url
    end
  end

  defp token_time(%DateTime{} = start_at), do: start_at
  defp token_time(_undated), do: nil

  @doc """
  Returns `description` with the "Join video call" line for `previous_url`
  taken out and one for `url` appended.

  Either URL may be `nil`: a new event has no previous link, and a removal has
  no new one.
  """
  @spec put_join_link(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t() | nil
  def put_join_link(description, previous_url, url) do
    description
    |> remove_join_line(previous_url)
    |> append_join_line(url)
  end

  defp remove_join_line(description, url) when is_binary(description) and is_binary(url) do
    line = join_line(url)

    if String.contains?(description, line) do
      ~r/\n*#{Regex.escape(line)}\n*/
      |> Regex.replace(description, "\n\n")
      |> String.trim()
    else
      description
    end
  end

  defp remove_join_line(description, _url), do: description

  defp append_join_line(description, nil), do: description
  defp append_join_line(description, url) when description in [nil, ""], do: join_line(url)
  defp append_join_line(description, url), do: description <> "\n\n" <> join_line(url)

  defp join_line(url), do: @join_line_prefix <> url

  defp create_room(user_id, event, video_integration_id) do
    # The event's iCal uid, the same identifier the creation flow passes as
    # `meeting_id`, so a provider that derives its room from it (a templated
    # custom link, say) produces the same room whether video was chosen when
    # the event was made or switched on afterwards.
    opts = [
      integration_id: video_integration_id,
      event_details: EventDetails.from_grid_event(event),
      meeting_id: event.uid
    ]

    case Video.create_meeting_room(user_id, opts) do
      {:ok, %{room_data: %{meeting_url: url}} = meeting_context}
      when is_binary(url) and url != "" ->
        :ok = record_room(meeting_context, event, video_integration_id, user_id)
        {:ok, join_link(meeting_context, Map.get(event, :start_at))}

      # A 2xx whose body lacks the URL still passes `RoomData`'s key check.
      # Saving `nil` would read as a deliberate removal and wipe the link the
      # event has, so the change is refused and the unusable room let go.
      {:ok, %{room_data: room_data}} ->
        Logger.warning("Video provider returned no meeting URL for an event video change",
          user_id: user_id,
          video_integration_id: video_integration_id
        )

        delete_room(user_id, video_integration_id, Map.get(room_data, :room_id))
        {:error, :missing_meeting_url}

      {:error, reason} = error ->
        Logger.warning("Failed to create a video room for an event video change",
          user_id: user_id,
          video_integration_id: video_integration_id,
          reason: inspect(reason)
        )

        error
    end
  end

  # Recorded as soon as the provider reports the room, so that a provider
  # whose rooms Tymeslot has to delete (Nextcloud Talk today) has its room
  # deleted with the event or once the event has ended, rather than left on
  # the organiser's server with nothing pointing at it.
  defp record_room(meeting_context, event, video_integration_id, user_id) do
    event_fields =
      Map.take(event, [
        :calendar_integration_id,
        :uid,
        :provider_event_id,
        :provider_calendar_id,
        :recurring_event_id,
        :recurrence_rule,
        :all_day,
        :start_at,
        :end_at,
        :start_date,
        :end_date
      ])

    EventVideoRooms.record(
      meeting_context,
      Map.merge(event_fields, %{user_id: user_id, video_integration_id: video_integration_id})
    )
  end

  # The new room is only referenced once the calendar has the link, so a
  # rejected write lets it go instead of leaving it unused on the provider.
  defp write_new_description(user_id, event, video_integration_id, url) do
    case write_description(user_id, event, url) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        discard_room(user_id, video_integration_id, url)
        error
    end
  end

  defp cache_link(event, video_integration_id, url) do
    case ProviderCalendarEventQueries.apply_local_edit(
           event.calendar_integration_id,
           event.uid,
           %{video_link: url, video_integration_id: video_integration_id}
         ) do
      {:ok, _row} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp write_description(user_id, event, url) do
    description = put_join_link(event.description, event.video_link, url)

    if description == event.description do
      :ok
    else
      case EventEdit.update_event(user_id, event, %{description: description}) do
        {:ok, _updated} -> :ok
        # Saved locally and replayed on the next sync, like any queued edit.
        {:error, %{retry: :queued}} -> :ok
        {:error, %{reason: reason}} -> {:error, reason}
      end
    end
  end

  # The integration names the provider outright, so the id is parsed by that
  # provider's rules rather than by whichever one claims the link's shape.
  defp discard_room(user_id, video_integration_id, url)
       when is_integer(video_integration_id) and is_binary(url) do
    case Video.fetch_integration_for_user(video_integration_id, user_id) do
      {:ok, integration} ->
        delete_room(
          user_id,
          video_integration_id,
          Video.extract_room_id(url, integration.provider)
        )

      {:error, :not_found} ->
        :ok
    end
  end

  defp discard_room(_user_id, _video_integration_id, _url), do: :ok

  defp delete_room(user_id, video_integration_id, room_id) when is_binary(room_id) do
    case Video.delete_meeting_room(user_id,
           integration_id: video_integration_id,
           room_id: room_id
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not delete a video room no longer used by a calendar event",
          user_id: user_id,
          video_integration_id: video_integration_id,
          reason: inspect(reason)
        )
    end
  end

  defp delete_room(_user_id, _video_integration_id, _room_id), do: :ok
end
