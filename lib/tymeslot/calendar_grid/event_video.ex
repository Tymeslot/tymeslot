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

  ## Google Meet from the calendar's own account

  On a Google event whose chosen Meet integration shares the calendar's Google
  account, Google makes the conference itself, as it does when the event is
  created from the grid (`Tymeslot.Integrations.MeetingProvisioning`). The
  update asks for one with `conferenceData` and `conferenceDataVersion=1`,
  the event is read back once for the link Google made, and no line is added
  to the description. Moving such an event to another room, or to "None",
  takes the conference off in the same write, so the event's Meet button does
  not stay beside the new link.

  ## Rooms

  A room that is no longer referenced (the one just replaced or removed, or a
  new one that could not be put on the event) is deleted through
  `Tymeslot.CalendarGrid.EventVideoDiscard`, which queues the delete with
  retries: by the room's record where `Tymeslot.CalendarGrid.EventVideoRooms`
  keeps one, otherwise by the id in its link where that is exact (Zoom).
  Rooms of any other provider are left in place.
  """

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.EventVideoDiscard
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Calendar.Operations, as: CalendarOperations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.MeetingProvisioning
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
    * `{:error, :linked_to_booking}` when the event is the calendar copy of a
      Tymeslot booking (see `ensure_video_changeable/1`). Nothing is changed;
    * `{:error, :missing_meeting_url}` when the provider created a room but
      returned no join URL, in which case the event keeps its current link;
    * `{:error, :meet_link_pending}` when Google took the request for a Meet
      conference but the event read back carries no link yet. The previous
      link is gone and the event keeps the integration without a link, so
      choosing Google Meet again fetches one;
    * `{:error, {:configuration_error, code}}` when the provider's own server
      refuses to create rooms, which
      `Tymeslot.Integrations.Video.RoomCreationError` puts into words for the
      organiser;
    * `{:error, reason}` when the room could not be created or the calendar
      rejected the change. Nothing is changed.
  """
  @spec change_event_video(pos_integer(), map(), pos_integer() | nil) ::
          {:ok, String.t() | nil | :unchanged}
          | {:error,
             :missing_meeting_url | :meet_link_pending | :not_found | :linked_to_booking | term()}
  def change_event_video(_user_id, %{video_integration_id: id, video_link: link}, id)
      when is_integer(id) and is_binary(link),
      do: {:ok, :unchanged}

  def change_event_video(_user_id, %{video_integration_id: nil, video_link: nil}, nil),
    do: {:ok, :unchanged}

  def change_event_video(user_id, event, video_integration_id) do
    with :ok <- ensure_video_changeable(event) do
      apply_video_change(user_id, event, video_integration_id)
    end
  end

  @doc """
  Whether the video of `event` may be changed from the grid: not when the
  event is the calendar copy of a Tymeslot booking, whose room belongs to the
  meeting. A room made here would be unrelated to the meeting's own, so the
  booking's confirmation, reminder and reschedule emails would keep pointing
  at the old one while the calendar showed the new one.
  """
  @spec ensure_video_changeable(map()) :: :ok | {:error, :linked_to_booking}
  def ensure_video_changeable(event) do
    if CalendarEvents.event_linked_to_booking?(
         event.calendar_integration_id,
         Map.get(event, :provider_event_id),
         event.uid
       ),
       do: {:error, :linked_to_booking},
       else: :ok
  end

  defp apply_video_change(user_id, event, nil) do
    with :ok <- write_description(user_id, event, nil, leave_conference(user_id, event)),
         :ok <- cache_link(event, nil, nil) do
      discard_replaced(user_id, event)
      {:ok, nil}
    end
  end

  defp apply_video_change(user_id, event, video_integration_id)
       when is_integer(video_integration_id) do
    with {:ok, _integration} <- Video.fetch_integration_for_user(video_integration_id, user_id) do
      if inline_meet?(user_id, event, video_integration_id),
        do: change_to_inline_meet(user_id, event, video_integration_id),
        else: change_to_room(user_id, event, video_integration_id)
    end
  end

  @doc """
  `event` as a successful `change_event_video/3` to `video_integration_id`
  wrote it, given the `url` it answered with: the new link and integration,
  and the description exactly as it was sent to the calendar.

  A Meet link Google made for the event is not written into the description
  (it lives on the event's own conference), so the description loses the old
  link's line and gains none. Every other link replaces the old line.
  """
  @spec changed_event(pos_integer(), map(), pos_integer() | nil, String.t() | nil) :: map()
  def changed_event(user_id, event, video_integration_id, url) do
    line_url = if inline_meet?(user_id, event, video_integration_id), do: nil, else: url

    %{
      event
      | video_integration_id: video_integration_id,
        video_link: url,
        description: put_join_link(event.description, event.video_link, line_url)
    }
  end

  # Whether Google makes the conference itself: a Meet integration sharing
  # the Google calendar's account (`MeetingProvisioning.plan/3`).
  defp inline_meet?(_user_id, _event, nil), do: false

  defp inline_meet?(user_id, event, video_integration_id),
    do:
      match?(
        {:inline, _video_id},
        MeetingProvisioning.plan(event.calendar_integration_id, video_integration_id, user_id)
      )

  defp change_to_room(user_id, event, video_integration_id) do
    with {:ok, url} <- create_room(user_id, event, video_integration_id),
         :ok <- write_new_description(user_id, event, video_integration_id, url),
         :ok <- cache_link(event, video_integration_id, url) do
      discard_replaced(user_id, event)
      {:ok, url}
    end
  end

  # A Google event whose Meet comes from the calendar's own Google account
  # gets its conference from Google, as when it is created from the grid: the
  # write asks for one, and the event is read back for the link Google made.
  # The previous room's line leaves the description, since Meet's link lives
  # on the event's own conference.
  defp change_to_inline_meet(user_id, event, video_integration_id) do
    with :ok <-
           write_description(user_id, event, nil,
             conference_data: ConferenceData.create_request()
           ),
         {:ok, url} <- read_meet_link(user_id, event),
         :ok <- cache_link(event, video_integration_id, url) do
      discard_replaced(user_id, event)
      {:ok, url}
    else
      {:error, :meet_link_pending} = error ->
        # The event has its conference, or will have; only the link is not
        # known yet. The integration is kept without a link, which is the
        # state in which choosing Google Meet again fetches one.
        _cached = cache_link(event, video_integration_id, nil)
        discard_replaced(user_id, event)
        error

      {:error, _reason} = error ->
        error
    end
  end

  # One read of the event, only after a write that asked Google for a Meet
  # conference: the update's own answer does not reach this layer.
  defp read_meet_link(user_id, event) do
    ref = %{
      uid: event.uid,
      provider_event_id: Map.get(event, :provider_event_id),
      calendar_id: Map.get(event, :provider_calendar_id)
    }

    with {:ok, [fetched | _rest]} <-
           CalendarOperations.fetch_event(ref, {event.calendar_integration_id, user_id}),
         url when is_binary(url) <-
           ConferenceData.meet_url_from_google_event(fetched.provider_metadata || %{}) do
      {:ok, url}
    else
      _no_link ->
        Logger.warning("Google Calendar did not return a Meet link after a video change",
          user_id: user_id,
          calendar_integration_id: event.calendar_integration_id
        )

        {:error, :meet_link_pending}
    end
  end

  # Moving away from a Meet conference Google made for the event takes that
  # conference off the event, or its Meet button would stay beside the new
  # link. Any other event's conference is left alone.
  defp leave_conference(user_id, event) do
    if inline_meet?(user_id, event, event.video_integration_id),
      do: [conference_data: ConferenceData.remove()],
      else: []
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

        case Map.get(room_data, :room_id) do
          room_id when is_binary(room_id) and room_id != "" ->
            EventVideoDiscard.discard(user_id, event, video_integration_id, {:id, room_id})

          _no_id ->
            :ok
        end

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
    case write_description(user_id, event, url, leave_conference(user_id, event)) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        EventVideoDiscard.discard(user_id, event, video_integration_id, {:link, url})
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

  defp write_description(user_id, event, url, opts) do
    description = put_join_link(event.description, event.video_link, url)

    if description == event.description and opts == [] do
      :ok
    else
      case EventEdit.update_event(user_id, event, %{description: description}, opts) do
        {:ok, _updated} -> :ok
        # Saved locally and replayed on the next sync, like any queued edit.
        {:error, %{retry: :queued}} -> :ok
        {:error, %{reason: reason}} -> {:error, reason}
      end
    end
  end

  # The room the event held before the change, now that nothing points at it.
  defp discard_replaced(user_id, event) do
    case event.video_link do
      link when is_binary(link) and link != "" ->
        EventVideoDiscard.discard(user_id, event, event.video_integration_id, {:link, link})

      _no_link ->
        :ok
    end
  end
end
