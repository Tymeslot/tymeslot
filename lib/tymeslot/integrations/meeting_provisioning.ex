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
  * `{:separate, video_id}` — any other combination. The video provider is called
    independently and the resulting URL is written into the event description.

  An edit follows the same plan: `Tymeslot.CalendarGrid.change_event_video/3`
  sends `conferenceData` with `conferenceDataVersion=1` on the update when the
  plan is `:inline`, and reads the event back for the link Google made, since
  the update's own answer does not reach it.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Events
  alias Tymeslot.Integrations.Calendar.Google.ConferenceData
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings.MeetingSchema

  # How long a booking's Teams meeting waits for the booking's own calendar
  # event before giving up on it (see `teams_room_placement/1`).
  @calendar_event_grace_seconds 120

  @type plan ::
          {:inline, video_id :: integer()}
          | {:separate, video_id :: integer()}
          | :none

  @doc """
  Returns the provisioning plan for the given combination of integrations.

  Detects the Google same-account case via a private overlap check.
  All other combinations yield `:separate` or `:none`.
  """
  @spec plan(integer() | nil, integer() | nil, integer()) :: plan()
  def plan(calendar_integration_id, video_integration_id, user_id)

  def plan(_cal_id, nil, _user_id), do: :none

  def plan(cal_id, vid_id, user_id)
      when is_integer(cal_id) and is_integer(vid_id) and is_integer(user_id) do
    if google_account_overlap?(cal_id, vid_id, user_id) do
      {:inline, vid_id}
    else
      {:separate, vid_id}
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

  For `:separate` and `:none`: returns `{:ok, video_context}` unchanged.
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
    with %{video_integration_id: vid_id, organizer_user_id: user_id}
         when is_integer(vid_id) and is_integer(user_id) <- meeting,
         {:ok, %{provider: "teams"} = video} <- Video.fetch_integration_for_user(vid_id, user_id),
         {:ok, %{integration_id: cal_id}} <- Events.get_booking_integration_info(meeting),
         {:ok, calendar} <- Calendar.get_integration(cal_id, user_id),
         true <- same_microsoft_account?(calendar, video) do
      booking_event_placement(meeting, cal_id)
    else
      _other -> :own_event
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # The event only counts once it is in the calendar the booking writes to: a
  # mapping left over from another integration names an event this Teams
  # account may not even be able to see.
  defp booking_event_placement(
         %MeetingSchema{provider_event_id: event_id, calendar_integration_id: cal_id},
         cal_id
       )
       when is_binary(event_id) and event_id != "",
       do: {:calendar_event, event_id}

  # The calendar job normally writes the event within seconds of the booking.
  # One that has not after the grace period is failing, and may never succeed,
  # so the meeting takes an event of its own rather than leave the booking
  # without a link: a second calendar entry is the lesser harm.
  defp booking_event_placement(%MeetingSchema{inserted_at: inserted_at}, _cal_id) do
    if DateTime.diff(DateTime.utc_now(), inserted_at, :second) < @calendar_event_grace_seconds,
      do: :awaiting_calendar_event,
      else: :own_event
  end

  # Both integrations record the account's Microsoft Entra object id (`oid`).
  defp same_microsoft_account?(%{provider: "outlook", provider_account_id: account_id}, %{
         provider_account_id: account_id
       })
       when is_binary(account_id) and account_id != "",
       do: true

  defp same_microsoft_account?(_calendar, _video), do: false

  # Returns true when the given calendar and video integrations both belong to
  # the same Google account (Google Calendar + Google Meet, sharing
  # provider_account_id). Returns false for any missing/mismatched case.
  defp google_account_overlap?(calendar_integration_id, video_integration_id, user_id) do
    with {:ok, cal} <- Calendar.get_integration(calendar_integration_id, user_id),
         {:ok, vid} <- Video.fetch_integration_for_user(video_integration_id, user_id),
         true <- cal.provider == "google" and vid.provider == "google_meet",
         account_id when is_binary(account_id) and account_id != "" <- cal.provider_account_id,
         true <- vid.provider_account_id == account_id do
      true
    else
      _other -> false
    end
  end
end
