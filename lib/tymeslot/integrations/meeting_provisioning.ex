defmodule Tymeslot.Integrations.MeetingProvisioning do
  @moduledoc """
  Cross-context orchestration: given a `(calendar_integration_id, video_integration_id,
  user_id, event_details)` tuple, decides whether to ask the calendar provider to
  provision the video link inline (via `conferenceData.createRequest`) or to provision
  it separately and stitch the URL into the event description afterwards.

  ## Strategies

  * `:none` — no video integration requested.
  * `{:inline, video_id}` — Google Calendar and Google Meet share the same Google
    account. Attaching `conferenceData.createRequest` to the calendar create/update
    call lets Google provision the Meet link in a single round-trip and avoids
    creating a duplicate calendar event.
  * `{:attach, video_id}`: an Outlook calendar and Microsoft Teams sharing the
    same Microsoft account. A Teams meeting is itself an Outlook event, so the
    calendar event is written first and the Teams provider then switches the
    online meeting on for that very event (its `:calendar_event_id` option),
    rather than creating a second event to carry the meeting. Kept apart from
    `:inline` because nothing is added to the calendar write itself: in
    particular it never reaches `attach_conference_data/2`, whose payload only
    Google understands.
  * `{:separate, video_id}` — any other combination. The video provider is called
    independently and the resulting URL is written into the event description.

  An edit follows the same plan: `Tymeslot.CalendarGrid.Changes.change_event_video/3`
  sends `conferenceData` with `conferenceDataVersion=1` on the update when the
  plan is `:inline`, and reads the event back for the link Google made, since
  the update's own answer does not reach it. On `:attach` it has the Teams
  provider attach the meeting to the existing event.

  ## Bookings

  `plan/3` decides for events created and edited on the dashboard calendar
  (`Tymeslot.CalendarGrid`). A booking follows the same two same-account
  rules, split between its two jobs, which run on separate queues:

    * `booking_event_video_fields/1` is what the calendar job creates the
      booking's event with: the Teams meeting switched on, or a Google
      `conferenceData.createRequest`.
    * `booking_room_placement/1` is where the video job finds the room: on
      that event, once it exists. A Teams meeting is attached to it, and a
      Meet conference Google made for it is read from it.

  Google Calendar replaces a Meet code made outside Calendar with one made
  for the event, so a booking on Google Calendar given a standalone Meet
  space would end up with two links: the one Tymeslot sent, and the one on
  the event. The Meet is therefore made with the event, as on the dashboard.
  Any other combination gets a room of its own from the video provider.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Defaults
  alias Tymeslot.Integrations.Calendar.Events
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviders
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviders
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.CalendarEventWorker

  # How long a booking's room waits for the booking's own calendar event, and
  # for the Meet conference Google makes on it, before giving up on it (see
  # `booking_room_placement/1`).
  @calendar_event_grace_seconds 120

  # How far apart two nodes' clocks may read: the calendar job and the video
  # job each measure the wait on their own node's clock against the same
  # `inserted_at`.
  @clock_skew_seconds 5

  @type plan ::
          {:inline, video_id :: integer()}
          | {:attach, video_id :: integer()}
          | {:separate, video_id :: integer()}
          | :none

  @doc """
  Returns the provisioning plan for the given combination of integrations.

  `:inline` for Google Calendar with Google Meet, and `:attach` for Outlook
  with Microsoft Teams, each only when both integrations belong to the same
  account. Any other usable video integration yields `:separate`.

  `:none` when no video is asked for, and also when the video integration is
  not one the user can use: another user's, disconnected, or switched off.
  Planning a room on it would only defer the refusal to the provider call.
  """
  @spec plan(integer() | nil, integer() | nil, integer()) :: plan()
  def plan(calendar_integration_id, video_integration_id, user_id)

  def plan(_cal_id, nil, _user_id), do: :none

  def plan(cal_id, vid_id, user_id)
      when is_integer(cal_id) and is_integer(vid_id) and is_integer(user_id) do
    case Video.fetch_live_integration_for_user(vid_id, user_id) do
      {:ok, %{is_active: true} = video} ->
        case Calendar.get_integration(cal_id, user_id) do
          {:ok, calendar} -> {placement(calendar, video), vid_id}
          _no_calendar -> {:separate, vid_id}
        end

      _unusable ->
        :none
    end
  end

  def plan(_cal_id, _vid_id, _user_id), do: :none

  @doc """
  Attaches the `conference_data` key to `event_data` when the plan is `:inline`.

  For any other plan the map is returned unchanged. This is the only place that
  builds the `conferenceData.createRequest` payload — no caller needs to know
  what it looks like.
  """
  @spec attach_conference_data(map(), plan()) :: map()
  def attach_conference_data(event_data, {:inline, _video_id}) do
    Map.put(event_data, :conference_data, ConferenceData.create_request())
  end

  def attach_conference_data(event_data, _plan), do: event_data

  @doc """
  Finalises the video context after the calendar create call completes.

  For the `:inline` plan: extracts the Meet URL from the provider's own answer
  to the create (`CreatedEvent.raw`) and builds the `video_context` map.

  Returns `{:ok, video_context}` on success. Returns
  `{:error, :no_meet_url, video_context}` when Google did not return a Meet URL
  (e.g. a pending `createRequest` or missing `entryPoints`). The error tuple
  still includes `video_integration_id` so callers can persist the integration
  association even without a URL.

  For every other plan: returns `{:ok, video_context}` unchanged. An `:attach`
  plan's meeting is made by the caller once the event exists, since it needs
  the id the calendar just gave the event.
  """
  @spec finalise(map(), CreatedEvent.t(), plan()) ::
          {:ok, map()} | {:error, :no_meet_url, map()}
  def finalise(video_context, %CreatedEvent{raw: raw}, {:inline, video_id}) do
    case ConferenceData.meet_url_from_event(raw) do
      nil ->
        Logger.warning(
          "Google Calendar create succeeded but did not return a Meet URL; " <>
            "the event has no video link",
          video_integration_id: video_id
        )

        {:error, :no_meet_url, Map.put(video_context, :video_integration_id, video_id)}

      url when is_binary(url) ->
        {:ok,
         Map.merge(video_context, %{
           meeting_url: url,
           # The `:inline` plan only exists for a Google Calendar and Google
           # Meet pair, so the link is a Meet link and Meet's rules parse it.
           room_id: Video.extract_room_id(url, :google_meet),
           video_integration_id: video_id
         })}
    end
  end

  def finalise(video_context, _created, _plan), do: {:ok, video_context}

  @doc """
  Where a booking's video room belongs, when its calendar can carry it.

  A booking written to a calendar of the same account as its video
  integration gets its room on the booking's own calendar event, so the
  organiser's calendar holds one entry and one link for the booking:

  * `{:calendar_event, provider_event_id}`: a Teams meeting, to be attached
    to the booking's Outlook event. A Teams meeting is itself an Outlook
    event, so a separate one would be a second calendar entry.
  * `{:calendar_meet, provider_event_id, meet_url}`: the Meet conference
    Google made on the booking's Google event, which was created asking for
    one (`booking_event_video_fields/1`). Google replaces a Meet code made
    outside Calendar with one of its own, so a separate Meet space would
    leave the guest's link and the event's link pointing at different rooms.
  * `:awaiting_calendar_event`: the room belongs on the booking's event,
    which `Tymeslot.Workers.CalendarEventWorker` has not written yet, or,
    for Google Meet, whose conference Google has not finished making.
    Creating a separate room meanwhile is exactly the duplicate this avoids,
    so the caller waits, for up to two minutes from the booking; after that
    the answer becomes `:own_event`.
  * `:own_event`: any other combination, including a video account that is
    not the calendar's (a host can connect several accounts): the room is
    made by the video provider on its own.
  * `{:error, :calendar_unavailable}`: the booking's Google event could not
    be read. Whether it carries a Meet is unknown, and a room of its own
    could be a second one, so the caller retries rather than make one.
  """
  @spec booking_room_placement(MeetingSchema.t()) ::
          {:calendar_event, String.t()}
          | {:calendar_meet, String.t(), String.t()}
          | :awaiting_calendar_event
          | :own_event
          | {:error, :calendar_unavailable}
  def booking_room_placement(%MeetingSchema{} = meeting) do
    case video_on_booking_calendar(meeting) do
      {:ok, :attach, _video, %{integration_id: cal_id}} ->
        booking_event_placement(meeting, cal_id, @calendar_event_grace_seconds)

      {:ok, :inline, _video, %{integration_id: cal_id} = calendar} ->
        meeting
        |> booking_event_placement(cal_id, @calendar_event_grace_seconds)
        |> with_event_meet(meeting, calendar)

      :error ->
        :own_event
    end
  end

  @doc """
  The fields a booking's calendar event is created with so that it carries
  the booking's room from the start, or an empty map when it should be
  created without one:

  * `%{online_meeting: fields}`: the Graph fields that switch a Teams meeting
    on for an Outlook event of the same Microsoft account. Graph mails the
    attendees of an organiser's event on every write to it, so an event
    created without the meeting and written again to switch it on would
    reach the guest as an invitation and then an update.
  * `%{conference_data: create_request}`: a Google
    `conferenceData.createRequest`, for a Google event of the same Google
    account as the Meet integration, so Google makes the Meet with the event.

  The video job then finds the room on the event
  (`booking_room_placement/1`) instead of making one.

  Fields are answered only while the room is still waiting for the event,
  and only while that wait has longer left than a calendar create can take.
  A create still in flight when the video job gives up waiting would leave
  the booking with two rooms, so the margin is the calendar job's own
  deadline for one run
  (`Tymeslot.Workers.CalendarEventWorker.attempt_timeout_ms/0`), past which
  the run cannot record the event, plus the clock skew between nodes. A run
  that adds the room therefore has recorded its event, or never will, before
  the video job can answer `:own_event`. A deadline as long as the wait
  itself leaves no time at all, and the event is created without the room,
  which costs a Teams guest an update but never a second room.
  """
  @spec booking_event_video_fields(MeetingSchema.t()) :: map()
  def booking_event_video_fields(%MeetingSchema{} = meeting) do
    grace = @calendar_event_grace_seconds - create_margin_seconds()

    with {:ok, how, video, %{integration_id: cal_id}} <- video_on_booking_calendar(meeting),
         :awaiting_calendar_event <- booking_event_placement(meeting, cal_id, grace) do
      event_video_fields(how, video)
    else
      _other -> %{}
    end
  end

  defp event_video_fields(:attach, video),
    do: %{online_meeting: TeamsProvider.online_meeting_fields(video)}

  defp event_video_fields(:inline, _video),
    do: %{conference_data: ConferenceData.booking_create_request()}

  @doc """
  The fields a booking's calendar update carries to take a Meet conference
  off its Google event, or an empty map.

  An ordinary update leaves an event's conference as it is. A conference the
  event was created asking for (`booking_event_video_fields/1`) that the
  booking no longer holds as its room, and no longer waits for, would then
  stay on the event: a booking moved to another location before the video
  job took the Meet would keep offering it. Such a conference is taken off
  (`%{conference_data: :remove}`). It is recognised on the cached copy of the
  event by its request id, so a conference the organiser added in Google
  Calendar is never touched; an event not cached yet keeps its conference.
  """
  @spec booking_event_update_fields(MeetingSchema.t()) :: map()
  def booking_event_update_fields(%MeetingSchema{
        provider_event_id: event_id,
        video_room_id: event_id
      })
      when is_binary(event_id),
      do: %{}

  def booking_event_update_fields(%MeetingSchema{provider_event_id: event_id} = meeting)
      when is_binary(event_id) and event_id != "" do
    with false <- match?({:ok, :inline, _video, _calendar}, video_on_booking_calendar(meeting)),
         {:ok, cached} <-
           ProviderCalendarEventQueries.get_by_identifiers(meeting.calendar_integration_id, [
             event_id
           ]),
         true <- ConferenceData.booking_conference?(cached.provider_metadata) do
      Logger.info("Taking the booking's Meet conference off its calendar event",
        meeting_id: meeting.id
      )

      %{conference_data: ConferenceData.remove()}
    else
      _keep -> %{}
    end
  end

  def booking_event_update_fields(_meeting), do: %{}

  # The booking's video integration, how the calendar it is written to
  # carries its room (`@same_account_rules`), and that calendar, when both
  # are the same account. The calendar is named as a create addresses it: the
  # booking's own calendar, else the integration's booking calendar.
  defp video_on_booking_calendar(meeting) do
    with %{video_integration_id: vid_id, organizer_user_id: user_id}
         when is_integer(vid_id) and is_integer(user_id) <- meeting,
         {:ok, video} <- Video.fetch_integration_for_user(vid_id, user_id),
         {how, calendar_provider} <- same_account_rule(video),
         {:ok, %{integration_id: cal_id} = booking_calendar} <-
           Events.get_booking_integration_info(meeting),
         {:ok, calendar} <- Calendar.get_integration(cal_id, user_id),
         true <- same_account?(calendar, video, calendar_provider) do
      calendar_id = booking_calendar.calendar_path || Defaults.booking_calendar_id(calendar)
      {:ok, how, video, %{integration_id: cal_id, calendar_id: calendar_id}}
    else
      _other -> :error
    end
  end

  # Google makes an event's Meet conference after answering the create, so
  # the event can exist without its link for a moment. The link is waited for
  # like the event itself, and for the same time: an event created without a
  # conference (late in the wait, see `booking_event_video_fields/1`) or one
  # Google never finishes is given a room of its own once the wait is over.
  defp with_event_meet({:calendar_event, event_id}, meeting, calendar) do
    case event_meet_url(meeting, event_id, calendar) do
      {:ok, url} -> {:calendar_meet, event_id, url}
      :none -> waiting_or_own_event(meeting, @calendar_event_grace_seconds)
      {:error, _reason} -> {:error, :calendar_unavailable}
    end
  end

  defp with_event_meet(placement, _meeting, _calendar), do: placement

  # The event is addressed by its Google id within the booking calendar; the
  # booking's own `uid` is its cancel and reschedule capability and is never
  # sent to a provider. Only an answer from Google about the event says it
  # has no Meet: an event Google no longer has, or one read without one. A
  # read that failed says nothing either way.
  defp event_meet_url(meeting, event_id, %{integration_id: cal_id, calendar_id: calendar_id}) do
    ref = %{provider_event_id: event_id, calendar_id: calendar_id}

    case Events.fetch_event(ref, {cal_id, meeting.organizer_user_id}) do
      {:ok, [event | _rest]} ->
        case ConferenceData.meet_url_from_google_event(Map.get(event, :provider_metadata) || %{}) do
          url when is_binary(url) -> {:ok, url}
          nil -> :none
        end

      {:error, :not_found} ->
        :none

      other ->
        Logger.warning("Booking's Google event could not be read for its Meet link",
          meeting_id: meeting.id,
          reason: LogFormat.reason(other)
        )

        {:error, :calendar_unavailable}
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Read on each call, as the worker reads its deadline, so the two cannot
  # drift apart when the deadline is configured.
  defp create_margin_seconds do
    ceil_div(CalendarEventWorker.attempt_timeout_ms(), 1_000) + @clock_skew_seconds
  end

  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)

  # The event only counts once it is in the calendar the booking writes to: a
  # mapping left over from another integration names an event this video
  # account may not even be able to see.
  defp booking_event_placement(
         %MeetingSchema{provider_event_id: event_id, calendar_integration_id: cal_id},
         cal_id,
         _grace_seconds
       )
       when is_binary(event_id) and event_id != "",
       do: {:calendar_event, event_id}

  # The calendar job normally writes the event within seconds of the booking.
  # One that has not after the grace period is failing, and may never succeed,
  # so the room is made on its own rather than leave the booking without a
  # link: a second calendar entry, or a second link, is the lesser harm.
  defp booking_event_placement(meeting, _cal_id, grace_seconds),
    do: waiting_or_own_event(meeting, grace_seconds)

  defp waiting_or_own_event(%MeetingSchema{inserted_at: inserted_at}, grace_seconds) do
    if DateTime.diff(Clock.utc_now(), inserted_at, :second) < grace_seconds,
      do: :awaiting_calendar_event,
      else: :own_event
  end

  # The video providers whose meeting the calendar of the same account can
  # carry, and how. Google Calendar and Google Meet: Google makes the
  # conference with the event. Teams on an Outlook calendar: the meeting goes
  # on the calendar event. `booking_room_placement/1` applies both to
  # bookings.
  @same_account_rules %{google_meet: {:inline, :google}, teams: {:attach, :outlook}}

  defp placement(calendar, video) do
    with {how, calendar_provider} <- same_account_rule(video),
         true <- same_account?(calendar, video, calendar_provider) do
      how
    else
      _other -> :separate
    end
  end

  defp same_account_rule(%{provider: provider}) do
    case VideoProviders.parse_known(provider) do
      {:ok, video_provider} -> Map.get(@same_account_rules, video_provider)
      {:error, :unknown} -> nil
    end
  end

  # Both integrations record the same account id: the Google account, or the
  # Microsoft Entra object id (`oid`).
  defp same_account?(
         %{provider: provider, provider_account_id: account_id},
         %{provider_account_id: account_id},
         calendar_provider
       )
       when is_binary(account_id) and account_id != "",
       do: CalendarProviders.parse_known(provider) == {:ok, calendar_provider}

  defp same_account?(_calendar, _video, _calendar_provider), do: false
end
