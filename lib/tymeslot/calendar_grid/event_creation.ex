defmodule Tymeslot.CalendarGrid.EventCreation do
  @moduledoc """
  Domain orchestration for creating calendar-grid events.

  Takes plain payload maps (never a LiveView socket) and is invoked from a
  supervised Task. Responsibilities:

    * build iCal event data from the dashboard create form,
    * plan and attach video-conference data (inline Google Meet or a
      separately-provisioned room),
    * call the calendar provider via `EventOperations`,
    * fire attendee notifications, and
    * look up integration metadata for the cache row.

  Side effects that need to reach the user (e.g. a "reconnect your calendar"
  flash) are surfaced as data in the returned `{:ok, result}` map — never via
  `send/2` back into the LiveView — because this code runs in a Task process
  whose mailbox the LiveView never reads. The web layer maps those flags to
  flashes.
  """

  require Logger

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.MeetingProvisioning
  alias Tymeslot.Integrations.Video.EventDetails
  alias Tymeslot.Integrations.Video.Rooms, as: VideoRooms
  alias Tymeslot.Meetings.AttendeeNotifications

  @reauth_flash_message "Your calendar needs to be reconnected. Please reconnect it from the Integrations page."

  @doc """
  Returns the flash message surfaced to the user when an integration's
  credentials require reauthentication during event creation.
  """
  @spec reauth_flash_message() :: String.t()
  def reauth_flash_message, do: @reauth_flash_message

  @doc """
  Creates a calendar event from a resolved create-form payload.

  The payload carries the `:creating` form map, the organiser `:user_id`, and
  the parsed `:start_at`/`:end_at` datetimes. On success the returned map
  carries everything the web layer needs to cache the event, notify the grid,
  and flash the user (including `:reauth_required` when the integration's
  credentials need re-encrypting). On failure it carries enough context for
  the web layer to queue an offline retry.
  """
  @spec run_create_event(map()) :: {:ok, map()} | {:error, term(), map()}
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
    # its own event to Google Calendar and surfaces the URL up-front.
    plan =
      MeetingProvisioning.plan(creating.integration_id, creating[:video_integration_id], user_id)

    video_context = provision_video_room_for_plan(plan, event_details, user_id)

    event_data =
      build_event_data(uid, creating, start_at, end_at, event_details, video_context, plan)

    result =
      calendar_operations_module().create_event(
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
      video_context: video_context
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

    attendees = Enum.map(event_details.attendees, fn a -> %{"email" => a.email} end)

    if attendees != [], do: Map.put(base_data, :attendees, attendees), else: base_data
  end

  defp finalise_create_result({:ok, created}, ctx) do
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
          "Google Calendar saved the event but didn't return a Meet link — " <>
            "please try again or add it manually."

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
    # Carry context so the LiveView can tag the cache row for offline
    # retry. Use the pre-generated UID so a later retry reconciles to
    # the same cache entry.
    {:error, reason,
     %{
       uid: ctx.uid,
       calendar_integration_id: ctx.creating.integration_id,
       summary: ctx.creating.title,
       start_time: ctx.start_at,
       end_time: ctx.end_at,
       location: ctx.creating[:location],
       description: ctx.creating[:description]
     }}
  end

  defp provision_video_room_for_plan(:none, _event_details, _user_id), do: %{}
  defp provision_video_room_for_plan({:inline, _video_id}, _event_details, _user_id), do: %{}

  defp provision_video_room_for_plan({:separate, video_id}, event_details, user_id) do
    provision_video_room(video_id, user_id, event_details)
  end

  defp build_create_success(created, creating, user_id, start_at, end_at, video_context) do
    uid = created_uid(created)

    {provider, default_booking_calendar_id, reauth_required?} =
      lookup_integration_metadata(creating.integration_id)

    meeting_url = video_context[:meeting_url]
    video_room_id = video_context[:room_id]

    notify_event = %{
      uid: uid,
      summary: creating.title,
      start_at: start_at,
      end_at: end_at,
      location: creating[:location],
      description: build_description(creating[:description], video_context),
      video_link: meeting_url,
      attendee_video_url: meeting_url,
      ical_sequence: 0,
      calendar_integration: %{user_id: user_id}
    }

    attendees =
      Enum.map(creating[:attendees] || [], fn email -> %{email: email} end)

    {:ok, _status} = AttendeeNotifications.event_created(notify_event, attendees)

    {:ok,
     %{
       uid: uid,
       creating: creating,
       start_at: start_at,
       end_at: end_at,
       provider: provider,
       default_booking_calendar_id: default_booking_calendar_id,
       reauth_required: reauth_required?,
       attendees: attendees,
       meeting_url: meeting_url,
       video_room_id: video_room_id,
       description: notify_event.description
     }}
  end

  defp calendar_operations_module do
    Application.get_env(:tymeslot, :event_create_operations_module, EventOperations)
  end

  defp provision_video_room(integration_id, user_id, event_details)
       when is_integer(integration_id) do
    opts = [integration_id: integration_id, event_details: event_details]

    case VideoRooms.create_meeting_room(user_id, opts) do
      {:ok, %{room_data: room_data}} ->
        %{
          meeting_url: room_data[:meeting_url] || room_data[:join_url],
          room_id: room_data[:room_id],
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

  # Providers return the created event either as a bare uid string, as an
  # atom-keyed map (the converted shape), or as a string-keyed map (a raw
  # payload). All three are answered here once.
  defp created_uid(created) when is_binary(created), do: created
  defp created_uid(%{uid: uid}) when is_binary(uid), do: uid
  defp created_uid(%{"uid" => uid}) when is_binary(uid), do: uid
  defp created_uid(_created), do: nil

  defp build_description(existing, video_context) do
    case video_context[:meeting_url] do
      nil ->
        existing

      url when is_binary(url) ->
        line = "Join video call: #{url}"

        case existing do
          nil -> line
          "" -> line
          text -> text <> "\n\n" <> line
        end
    end
  end

  # Returns `{provider, default_booking_calendar_id, reauth_required?}`.
  #
  # When the integration's credentials require re-encryption we still flag it
  # for reauth here (a database write that works regardless of process), but we
  # signal the user-facing "reconnect" condition by returning `true` rather than
  # sending a flash — this runs in a Task whose mailbox the LiveView never
  # reads. The web layer maps the flag to a flash.
  defp lookup_integration_metadata(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
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
