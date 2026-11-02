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

  An edit follows the same plan: `Tymeslot.CalendarGrid.change_event_video/3`
  sends `conferenceData` with `conferenceDataVersion=1` on the update when the
  plan is `:inline`, and reads the event back for the link Google made, since
  the update's own answer does not reach it. On `:attach` it has the Teams
  provider attach the meeting to the existing event.

  ## Scope: dashboard events, not bookings

  `plan/3` decides for events created and edited on the dashboard calendar
  (`Tymeslot.CalendarGrid`). Bookings do not go through it yet:
  `Tymeslot.Meetings.VideoRooms` provisions every booking's room on its own,
  so a booking on Google Calendar with Google Meet gets a standalone Meet
  space whose link is written into the event, not inline conference data.
  The one decision bookings share is where a Teams meeting goes
  (`teams_room_placement/1`), and with it whether the booking's Outlook event
  is created carrying the meeting (`booking_online_meeting/1`).
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Events
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviders
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviders
  alias Tymeslot.Integrations.Video.Providers.TeamsProvider
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Workers.CalendarEventWorker

  # How long a booking's Teams meeting waits for the booking's own calendar
  # event before giving up on it (see `teams_room_placement/1`).
  @calendar_event_grace_seconds 120

  # How far apart two nodes' clocks may read: the calendar job and the Teams
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
  Where a booking's Microsoft Teams meeting belongs.

  A Teams meeting is an Outlook calendar event with an online meeting on it.
  When the booking is written to an Outlook calendar of the same Microsoft
  account as its Teams integration, that event already exists, so the meeting
  is attached to it and the organiser's calendar holds one entry for the
  booking instead of two:

  * `{:calendar_event, provider_event_id}` — attach it to the booking's event.
  * `:awaiting_calendar_event` — it belongs on the booking's event, which
    `Tymeslot.Workers.CalendarEventWorker` has not written yet. Creating a
    separate event meanwhile is exactly the duplicate this avoids, so the
    caller waits for it, for up to two minutes from the booking; after that
    the answer becomes `:own_event`.
  * `:own_event` — any other combination, including a Teams account that is
    not the calendar's (a host can connect several Outlook accounts): the
    meeting needs an event of its own.
  """
  @spec teams_room_placement(MeetingSchema.t()) ::
          {:calendar_event, String.t()} | :awaiting_calendar_event | :own_event
  def teams_room_placement(%MeetingSchema{} = meeting) do
    case teams_on_booking_calendar(meeting) do
      {:ok, _video, cal_id} ->
        booking_event_placement(meeting, cal_id, @calendar_event_grace_seconds)

      :error ->
        :own_event
    end
  end

  @doc """
  The Graph fields a booking's Outlook event is created with so that it
  carries the booking's Teams meeting from the start, or nil when it should
  be created without one.

  Graph mails the attendees of an organiser's event on every write to it.
  Created without the meeting, the event is written again to switch the
  meeting on, so the guest gets an invitation without the meeting and then
  an update with it (issue #191). Created with it, the one invitation carries
  the meeting, and the Teams provider finds it there
  (`teams_room_placement/1`'s `{:calendar_event, id}`) instead of writing.

  Fields are answered only while the meeting is still waiting for the event,
  and only while that wait has longer left than a calendar create can take.
  A create still in flight when the Teams job gives up waiting would leave
  the account with two Teams meetings and the guest with two invitations, so
  the margin is the calendar job's own deadline for one run
  (`Tymeslot.Workers.CalendarEventWorker.attempt_timeout_ms/0`), past which
  the run cannot record the event, plus the clock skew between nodes. A run
  that adds the meeting therefore has recorded its event, or never will,
  before the Teams job can answer `:own_event`. A deadline as long as the
  wait itself leaves no time at all, and the event is created without the
  meeting, which costs the guest an update but never a second meeting.
  """
  @spec booking_online_meeting(MeetingSchema.t()) :: map() | nil
  def booking_online_meeting(%MeetingSchema{} = meeting) do
    grace = @calendar_event_grace_seconds - create_margin_seconds()

    with {:ok, video, cal_id} <- teams_on_booking_calendar(meeting),
         :awaiting_calendar_event <- booking_event_placement(meeting, cal_id, grace) do
      TeamsProvider.online_meeting_fields(video)
    else
      _other -> nil
    end
  end

  # The booking's Teams integration and the calendar integration it is
  # written to, when both are the same Microsoft account.
  defp teams_on_booking_calendar(meeting) do
    with %{video_integration_id: vid_id, organizer_user_id: user_id}
         when is_integer(vid_id) and is_integer(user_id) <- meeting,
         {:ok, video} <- Video.fetch_integration_for_user(vid_id, user_id),
         {:attach, calendar_provider} <- same_account_rule(video),
         {:ok, %{integration_id: cal_id}} <- Events.get_booking_integration_info(meeting),
         {:ok, calendar} <- Calendar.get_integration(cal_id, user_id),
         true <- same_account?(calendar, video, calendar_provider) do
      {:ok, video, cal_id}
    else
      _other -> :error
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
  # mapping left over from another integration names an event this Teams
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
  # so the meeting takes an event of its own rather than leave the booking
  # without a link: a second calendar entry is the lesser harm.
  defp booking_event_placement(%MeetingSchema{inserted_at: inserted_at}, _cal_id, grace_seconds) do
    if DateTime.diff(Clock.utc_now(), inserted_at, :second) < grace_seconds,
      do: :awaiting_calendar_event,
      else: :own_event
  end

  # The video providers whose meeting the calendar of the same account can
  # carry, and how. Google Calendar and Google Meet: Google makes the
  # conference with the event. Teams on an Outlook calendar: the meeting goes
  # on the calendar event, the rule `teams_room_placement/1` applies to
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
