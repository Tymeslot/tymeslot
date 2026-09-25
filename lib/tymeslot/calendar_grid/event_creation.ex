defmodule Tymeslot.CalendarGrid.EventCreation do
  @moduledoc """
  Domain orchestration for creating calendar-grid events.

  Takes plain payload maps (never a LiveView socket) and is invoked from a
  supervised Task. Responsibilities:

    * build iCal event data from the dashboard create form,
    * plan and attach video-conference data (inline Google Meet, a Teams
      meeting attached to the Outlook event once it is written, or a
      separately-provisioned room),
    * call the calendar provider via `Calendar.Events`, queueing a failed
      create for offline retry,
    * drop the organiser's cached availability so the newly blocked time
      stops being offered on the booking page,
    * fire attendee notifications, and
    * look up integration metadata for the cache row.

  Side effects that need to reach the user (e.g. a "reconnect your calendar"
  flash) are surfaced as data in the returned `{:ok, result}` map — never via
  `send/2` back into the LiveView — because this code runs in a Task process
  whose mailbox the LiveView never reads. The web layer maps those flags to
  flashes.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.CalendarGrid.EventVideo
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.MeetingProvisioning
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Rooms, as: VideoRooms
  alias Tymeslot.Meetings.AttendeeNotifications

  @doc """
  Returns the flash message surfaced to the user when an integration's
  credentials require reauthentication during event creation.
  """
  @spec reauth_flash_message() :: String.t()
  def reauth_flash_message,
    do:
      dgettext(
        "dashboard_calendar_events",
        "Your calendar needs to be reconnected. Please reconnect it from the Integrations page."
      )

  @doc """
  Creates a calendar event from a resolved create-form payload.

  The payload carries the `:creating` form map, the organiser `:user_id`, and
  the parsed `:start_at`/`:end_at` datetimes. On success the returned map
  carries everything the web layer needs to cache the event, notify the grid,
  and flash the user (including `:reauth_required` when the integration's
  credentials need re-encrypting).

  A failed create is queued for replay on the next sync when the error is one
  a retry can recover (see `Calendar.Events.queueable_error?/1`) and the
  integration has an offline queue (the CalDAV family), and the failure reports
  `retry: :queued`; otherwise `retry: :not_queued`.
  """
  @spec run_create_event(map()) ::
          {:ok, map()} | {:error, %{reason: term(), retry: :queued | :not_queued}}
  def run_create_event(payload) do
    %{creating: creating, user_id: user_id, start_at: start_at, end_at: end_at} = payload

    # Generate the UID upfront so both the provider write AND the offline
    # queue tag (on failure) reference the same identifier. CalDAV PUTs
    # with a caller-supplied UID are addressed by that UID server-side,
    # so a retry targets the same event.
    uid = ICalBuilder.generate_uid()

    # Canonical event-details shape used by the video provider and the
    # provisioning strategy. Times are merged from the resolved start_at/end_at
    # since they are only available after parsing the form dates.
    event_details =
      EventDetails.from_creating_form(
        Map.merge(creating, %{start_time: start_at, end_time: end_at})
      )

    # Decide how to attach a Google Meet link (if any). The "inline" strategy
    # piggybacks a `conferenceData.createRequest` onto the calendar create
    # itself (avoiding a duplicate event) when both the calendar and video
    # integrations point at the same Google account. The "separate" strategy
    # falls back to provisioning a Meet via the video provider, which writes
    # its own event to Google Calendar and surfaces the URL up-front. The
    # "attach" strategy is Teams on the Outlook calendar's own Microsoft
    # account: the meeting is switched on for the event once it is written.
    plan =
      MeetingProvisioning.plan(creating.integration_id, creating[:video_integration_id], user_id)

    # What recording a room made for this event needs: the event's identity in
    # the calendar and its timing (see `EventVideoRooms.record/2`).
    grid_event = %{
      user_id: user_id,
      calendar_integration_id: creating.integration_id,
      uid: uid,
      all_day: Map.get(creating, :all_day, false),
      start: start_at,
      end: end_at,
      recurrence_rule: Map.get(creating, :recurrence_rule)
    }

    video_context = provision_video_room_for_plan(plan, event_details, grid_event)

    event_data =
      build_event_data(uid, creating, start_at, end_at, event_details, video_context, plan)

    result =
      CalendarEvents.create_event(
        event_data,
        {creating.integration_id, user_id}
      )

    finalise_create_result(result, %{
      uid: uid,
      creating: creating,
      user_id: user_id,
      start_at: start_at,
      end_at: end_at,
      plan: plan,
      video_context: video_context,
      event_details: event_details,
      grid_event: grid_event
    })
  end

  @doc """
  Creates an ad-hoc meeting from a flat params map (used by the calendar grid's
  ad-hoc creation flow).
  """
  @spec run_create_ad_hoc_meeting(map()) :: {:ok, map()} | {:error, term()}
  def run_create_ad_hoc_meeting(params) do
    ad_hoc_params = %{
      title: params.title,
      start_time: params.start_time,
      end_time: params.end_time,
      attendee_name: params.attendee_name,
      attendee_email: params.attendee_email,
      attendee_timezone: params[:attendee_timezone] || "Etc/UTC",
      organizer_user_id: params.organizer_user_id,
      calendar_integration_id: params[:calendar_integration_id],
      calendar_path: params[:calendar_id],
      video_integration_id: params[:video_integration_id]
    }

    case CreateAdHoc.execute(ad_hoc_params) do
      {:ok, meeting} ->
        {:ok, %{meeting_id: meeting.id, start_at: params.start_time, end_at: params.end_time}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private

  defp build_event_data(uid, creating, start_at, end_at, event_details, video_context, plan) do
    description = build_description(creating[:description], video_context)

    # For all-day events `start_at`/`end_at` are `Date` structs and `all_day`
    # is true — the provider mappers emit date-only values (Google `start.date`,
    # Outlook `isAllDay`, CalDAV `DTSTART;VALUE=DATE`) from a `Date` start/end.
    raw_base = %{
      uid: uid,
      summary: creating.title,
      start_time: start_at,
      end_time: end_at,
      all_day: Map.get(creating, :all_day, false),
      reminders: Map.get(creating, :reminders, []),
      recurrence_rule: Map.get(creating, :recurrence_rule),
      calendar_integration_id: creating.integration_id,
      calendar_id: creating[:calendar_id],
      description: description
    }

    base_data = MeetingProvisioning.attach_conference_data(raw_base, plan)

    case event_details.attendees do
      [] -> base_data
      attendees -> Map.put(base_data, :attendees, attendees)
    end
  end

  defp finalise_create_result({:ok, %CreatedEvent{} = created}, ctx) do
    # Google and Outlook address the event by the id they returned, not by the
    # uid it was written under, so a room recorded under that uid learns it,
    # and Google only within the calendar it was written to. The provider's
    # own answer names that calendar where it reports one; the form's choice
    # is the fallback for the providers that do not.
    if ctx.video_context[:room_id],
      do:
        :ok =
          EventVideoRooms.identified(
            ctx.creating.integration_id,
            ctx.uid,
            CreatedEvent.local_uid(created),
            created.calendar_id || written_calendar_id(ctx.creating)
          )

    ctx = attach_video_room(ctx, created)

    case MeetingProvisioning.finalise(ctx.video_context, created, ctx.plan) do
      {:ok, video_context} ->
        build_create_success(
          created,
          ctx.creating,
          ctx.user_id,
          ctx.start_at,
          ctx.end_at,
          video_context
        )

      {:error, :no_meet_url, video_context} ->
        warning =
          dgettext(
            "dashboard_calendar_events",
            "Google Calendar saved the event but didn't return a Meet link — please try again or add it manually."
          )

        {:ok, result} =
          build_create_success(
            created,
            ctx.creating,
            ctx.user_id,
            ctx.start_at,
            ctx.end_at,
            video_context
          )

        {:ok, Map.put(result, :warning, warning)}
    end
  end

  defp finalise_create_result({:error, reason}, ctx) do
    {:error, %{reason: reason, retry: queue_retry(ctx, reason)}}
  end

  # The queued row carries the pre-generated UID, so the replayed create
  # addresses the same event the failed one tried to write.
  #
  # Deliberately no availability invalidation: a queued create exists on no
  # server yet, and availability is fetched from the providers rather than
  # read out of this table, so the slot is genuinely still free and dropping
  # the organiser's entries would only make the next booking page slower. The
  # sync that flushes the queue invalidates when the create actually lands.
  defp queue_retry(ctx, reason) do
    target = %{uid: ctx.uid, calendar_integration_id: ctx.creating.integration_id}

    event_data = %{
      summary: ctx.creating.title,
      start_time: ctx.start_at,
      end_time: ctx.end_at,
      location: ctx.creating[:location],
      description: ctx.creating[:description]
    }

    with true <- CalendarEvents.queueable_error?(reason),
         :ok <- CalendarEvents.queue_for_offline_retry(target, :create, event_data) do
      :queued
    else
      _not_queued -> :not_queued
    end
  end

  # An all-day create carries its dates in `start_at`/`end_at` (see
  # `build_event_data/7`); the invitation reads an all-day event by the same
  # fields a cached one has, so they are renamed to match.
  defp notify_timing(%{all_day: true}, %Date{} = start_date, %Date{} = end_date),
    do: %{all_day: true, start_date: start_date, end_date: end_date}

  defp notify_timing(_creating, start_at, end_at), do: %{start_at: start_at, end_at: end_at}

  defp provision_video_room_for_plan(:none, _event_details, _grid_event), do: %{}

  defp provision_video_room_for_plan({:inline, _video_id}, _event_details, _grid_event),
    do: %{}

  # Made in `attach_video_room/2`, once the calendar has named the event.
  defp provision_video_room_for_plan({:attach, _video_id}, _event_details, _grid_event),
    do: %{}

  defp provision_video_room_for_plan({:separate, video_id}, event_details, grid_event) do
    provision_video_room(video_id, event_details, grid_event)
  end

  # Teams on the Outlook calendar's own Microsoft account: the meeting is
  # switched on for the event just written, addressed by the id Outlook gave
  # it, so the organiser's calendar holds the event once rather than beside a
  # second one carrying the meeting. The link lives on the event's own online
  # meeting, as a Meet link Google makes lives on its conference, so the
  # description written to the calendar carries no line for it.
  defp attach_video_room(%{plan: {:attach, video_id}} = ctx, %CreatedEvent{
         provider_event_id: event_id
       })
       when is_binary(event_id) and event_id != "" do
    video_context =
      provision_video_room(
        video_id,
        ctx.event_details,
        Map.put(ctx.grid_event, :provider_event_id, event_id),
        calendar_event_id: event_id
      )

    %{ctx | video_context: video_context}
  end

  # Outlook answered without naming the event: nothing to attach the meeting
  # to, and a meeting on an event of its own now could not be written into the
  # description already sent. The event keeps its integration with no link,
  # from which choosing Teams again provisions one.
  defp attach_video_room(%{plan: {:attach, video_id}} = ctx, _created) do
    Logger.warning("Outlook did not name the event it created; no Teams meeting attached",
      user_id: ctx.user_id,
      video_integration_id: video_id
    )

    ctx
  end

  defp attach_video_room(ctx, _created), do: ctx

  defp build_create_success(
         %CreatedEvent{} = created,
         creating,
         user_id,
         start_at,
         end_at,
         video_context
       ) do
    # The key the provider's sync caches the event under: Google and Outlook
    # report an iCalendar UID of their own, and a row cached under their event
    # id instead would be joined by a second one on the next sync.
    uid = CreatedEvent.cache_uid(created)

    {provider, default_booking_calendar_id, reauth_required?} =
      lookup_integration_metadata(creating.integration_id)

    meeting_url = video_context[:meeting_url]
    video_room_id = video_context[:room_id]

    notify_event =
      creating
      |> notify_timing(start_at, end_at)
      |> Map.merge(%{
        uid: uid,
        summary: creating.title,
        location: creating[:location],
        description: build_description(creating[:description], video_context),
        video_link: meeting_url,
        attendee_video_url: meeting_url,
        ical_sequence: 0,
        calendar_integration: %{user_id: user_id}
      })

    attendees =
      Enum.map(creating[:attendees] || [], fn email -> %{email: email} end)

    # The provider write has landed, so the organiser is now busy for this
    # slot. Availability is memoised per user, so without this the booking
    # page keeps offering the hour the host has just blocked until the entries
    # expire. Drawing an event on the grid is the ordinary way to make oneself
    # unavailable, so it is the write path that most needs the drop. Both
    # `finalise_create_result/2` success clauses funnel through here, and the
    # failure clause does not, so a queued create is left alone.
    AvailabilityCache.invalidate_for_user(user_id)

    {:ok, _status} = AttendeeNotifications.event_created(notify_event, attendees)

    # The provider's answer to the create is the only place the event's
    # server-side identity is free: after this it costs a sync. Both fields are
    # optional (a CalDAV server need not answer a PUT with an ETag, and no
    # provider is obliged to name the resource), so they travel as whatever the
    # provider reported, including nil.
    {:ok,
     %{
       uid: uid,
       creating: creating,
       start_at: start_at,
       end_at: end_at,
       provider: provider,
       provider_event_id: created.provider_event_id,
       written_calendar_id: created.calendar_id,
       etag: created.etag,
       default_booking_calendar_id: default_booking_calendar_id,
       reauth_required: reauth_required?,
       attendees: attendees,
       meeting_url: meeting_url,
       video_room_id: video_room_id,
       description: notify_event.description
     }}
  end

  # The calendar the provider wrote the event to: the one picked in the form,
  # else the integration's booking calendar, as the provider resolves it.
  defp written_calendar_id(%{calendar_id: calendar_id})
       when is_binary(calendar_id) and calendar_id != "",
       do: calendar_id

  defp written_calendar_id(creating) do
    case CalendarIntegrationQueries.get(creating.integration_id) do
      {:ok, %{default_booking_calendar_id: calendar_id}} when is_binary(calendar_id) ->
        calendar_id

      _no_booking_calendar ->
        "primary"
    end
  end

  defp provision_video_room(
         integration_id,
         event_details,
         %{user_id: user_id} = grid_event,
         extra_opts \\ []
       )
       when is_integer(integration_id) do
    opts =
      [
        integration_id: integration_id,
        event_details: event_details,
        meeting_id: grid_event.uid
      ] ++ extra_opts

    case VideoRooms.create_meeting_room(user_id, opts) do
      {:ok, %{room_data: room_data} = meeting_context} ->
        # Recorded as soon as the room exists, before the calendar write: a
        # room whose event never reaches the calendar still falls due.
        :ok =
          EventVideoRooms.record(
            meeting_context,
            Map.put(grid_event, :video_integration_id, integration_id)
          )

        %{
          # The description, the cached link and the invitees' notification
          # all publish one link that names nobody, so it is the shared one
          # rather than the bare room URL a token-enforcing server refuses.
          # See `EventVideo.join_link/2`.
          meeting_url: EventVideo.join_link(meeting_context, Map.get(grid_event, :start)),
          room_id: room_data.room_id,
          video_integration_id: integration_id
        }

      {:error, reason} ->
        Logger.warning("Failed to provision video room for new event",
          user_id: user_id,
          video_integration_id: integration_id,
          reason: inspect(reason)
        )

        %{}
    end
  end

  defp build_description(existing, video_context),
    do: EventVideo.put_join_link(existing, nil, video_context[:meeting_url])

  # Returns `{provider, default_booking_calendar_id, reauth_required?}`.
  #
  # When the integration's credentials require re-encryption we still flag it
  # for reauth here (a database write that works regardless of process), but we
  # signal the user-facing "reconnect" condition by returning `true` rather than
  # sending a flash — this runs in a Task whose mailbox the LiveView never
  # reads. The web layer maps the flag to a flash.
  #
  # An integration already flagged (its provider refused the credentials) gets
  # the same signal: the booking client never writes to a flagged integration,
  # so the event the user just created landed in another of their calendars,
  # and reconnecting is the only thing that puts the one they picked back.
  defp lookup_integration_metadata(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, %{needs_reauth: true} = integration} ->
        {integration.provider, integration.default_booking_calendar_id, true}

      {:ok, integration} ->
        {integration.provider, integration.default_booking_calendar_id, false}

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
        {nil, nil, true}

      {:error, _reason} ->
        {nil, nil, false}
    end
  end
end
