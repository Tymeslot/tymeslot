defmodule Tymeslot.Bookings.MeetingAttributes do
  @moduledoc """
  Assembles the attributes a booking's meeting row is written with, for every
  path that books one (`Tymeslot.Bookings.Create`, `CreateGroup`,
  `RescheduleSeat`).

  Not a pure transformation: it resolves the organiser's profile, schedule,
  meeting type, calendar and video integrations along the way.
  """

  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.Bookings.BuildParams
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Clock
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Reminders
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Timezones

  @typedoc "A single reminder entry with a numeric value and a unit string (e.g. \"minutes\")."
  @type reminder :: %{required(:value) => integer(), required(:unit) => String.t()}

  @typedoc "Complete set of meeting attributes built for persistence or email."
  @type meeting_attributes :: %{
          required(:uid) => String.t(),
          required(:title) => String.t(),
          required(:summary) => String.t(),
          required(:description) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:duration) => integer(),
          required(:location) => String.t() | nil,
          required(:location_kind) => String.t() | nil,
          required(:location_option_id) => String.t() | nil,
          required(:meeting_type) => String.t(),
          required(:meeting_type_id) => integer() | nil,
          required(:organizer_name) => String.t(),
          required(:organizer_email) => String.t(),
          required(:organizer_title) => String.t() | nil,
          required(:organizer_user_id) => integer() | nil,
          required(:calendar_integration_id) => integer() | nil,
          required(:calendar_path) => String.t() | nil,
          required(:video_integration_id) => integer() | nil,
          required(:venue_id) => integer() | nil,
          required(:address_to_arrange) => boolean(),
          required(:attendee_name) => String.t(),
          required(:attendee_email) => String.t(),
          required(:attendee_message) => String.t() | nil,
          required(:attendee_phone) => String.t() | nil,
          required(:attendee_company) => String.t() | nil,
          required(:attendee_timezone) => String.t(),
          required(:attendee_locale) => String.t(),
          required(:status) => String.t(),
          required(:approval_requested_at) => DateTime.t() | nil,
          required(:approval_deadline_at) => DateTime.t() | nil,
          required(:reminders) => [reminder()],
          required(:show_as_free) => boolean(),
          required(:attachments_snapshot) => [map()],
          required(:view_url) => String.t(),
          required(:reschedule_url) => String.t(),
          required(:cancel_url) => String.t(),
          required(:meeting_url) => String.t() | nil,
          required(:custom_fields_snapshot) => [map()],
          required(:custom_field_answers) => map(),
          required(:utm_source) => String.t() | nil,
          required(:utm_medium) => String.t() | nil,
          required(:utm_campaign) => String.t() | nil,
          required(:utm_content) => String.t() | nil,
          required(:utm_term) => String.t() | nil,
          required(:referrer_host) => String.t() | nil,
          required(:tracking_params) => map(),
          required(:visitor_hash) => String.t() | nil
        }

  @doc """
  Builds meeting attributes from parameters and form data.

  Resolves the organiser's profile, schedule and integrations along the way, so
  this reads from the database rather than being a pure transformation.
  """
  @spec build(BuildParams.t()) :: meeting_attributes()
  def build(%BuildParams{} = params) do
    meeting_uid = params.meeting_uid
    organizer_user_id = params.organizer_user_id
    meeting_type_id = params.meeting_type_id

    # Resolve meeting type if ID provided
    meeting_type_record = resolve_meeting_type_record(meeting_type_id, organizer_user_id)

    # Get organizer details from profile if available
    {org_name, org_email, org_username} = get_organizer_details(organizer_user_id)

    # Resolve attendee timezone
    config = Schedules.booking_config(organizer_user_id, meeting_type_record)
    user_timezone = params.user_timezone || config.owner_timezone

    # Get calendar integration info
    {calendar_integration_id, calendar_path} =
      get_calendar_integration_info(meeting_type_record || organizer_user_id)

    # Resolve meeting type details
    {meeting_type_name, resolved_meeting_type_id, video_integration_id} =
      resolve_meeting_type_details(meeting_type_record, params, organizer_user_id)

    # Get reminder configuration
    reminders = get_meeting_reminders(meeting_type_record)

    # A meeting type requiring manual approval holds its bookings instead of
    # confirming them. The deadline is stamped here, at request time, rather
    # than derived later: the meeting type's window can be edited — or the type
    # archived — while a request is outstanding, and the deadline promised to
    # the invitee must not move underneath them.
    %{status: status, approval_requested_at: requested_at, approval_deadline_at: deadline_at} =
      approval_attributes(meeting_type_record, params.start_datetime)

    # Build complete meeting attributes map
    %{
      uid: meeting_uid,
      start_time: params.start_datetime,
      end_time: params.end_datetime,
      duration: params.duration_minutes,
      meeting_type: meeting_type_name,
      meeting_type_id: resolved_meeting_type_id,
      organizer_name: org_name,
      organizer_email: org_email,
      organizer_title: nil,
      organizer_user_id: organizer_user_id,
      calendar_integration_id: calendar_integration_id,
      calendar_path: calendar_path,
      status: status,
      approval_requested_at: requested_at,
      approval_deadline_at: deadline_at,
      reminders: reminders,
      custom_fields_snapshot: params.custom_fields_snapshot,
      custom_field_answers: params.custom_field_answers
    }
    |> Map.merge(meeting_type_attributes(meeting_type_record))
    |> Map.merge(title_attributes(params, meeting_type_name))
    |> Map.merge(attendee_attributes(params, user_timezone))
    |> Map.merge(location_attributes(meeting_type_record, params, video_integration_id))
    |> Map.merge(source_attribution(params))
    |> Map.merge(build_meeting_action_urls(meeting_uid, org_username))
  end

  # What the booking copies from its meeting type, with the defaults for a
  # booking made without one.
  defp meeting_type_attributes(nil),
    do: %{description: "", show_as_free: false, attachments_snapshot: []}

  defp meeting_type_attributes(meeting_type_record) do
    %{
      description: meeting_type_record.description || "",
      show_as_free: meeting_type_record.show_as_free || false,
      attachments_snapshot: attachments_snapshot(meeting_type_record)
    }
  end

  # The title is stored once and becomes the organiser's calendar event and
  # dashboard entry, so it is rendered in the organiser's language, matching
  # the event description `CalendarEventBuilder` writes alongside it. Mail to
  # the booker renders it again in theirs (`BookingTitle.localise/1`).
  defp title_attributes(%BuildParams{} = params, meeting_type_name) do
    title =
      RecipientLocale.with_user_id_locale(params.organizer_user_id, fn ->
        BookingTitle.render(meeting_type_name, params.form_data["name"])
      end)

    %{title: title, summary: title}
  end

  # Who the booking is for, as they gave it. `attendee_phone` is deliberately
  # absent: it is set by `location_attributes/3` when, and only when, the
  # chosen location asked the booker for a number.
  defp attendee_attributes(%BuildParams{form_data: form_data} = params, user_timezone) do
    %{
      attendee_name: form_data["name"],
      attendee_email: form_data["email"],
      attendee_message: form_data["message"],
      attendee_company: nil,
      attendee_timezone: Timezones.normalize(user_timezone),
      attendee_locale: params.attendee_locale || default_locale()
    }
  end

  # Where the meeting is held, and everything that follows from it: the
  # display string, the kind, the video integration a room would be created
  # on, and the saved venue an in-person booking is at.
  #
  # The booker submitted only an option id, and within a video option the
  # provider they picked, or within an in-person option the venue. The rest
  # is re-derived here from the host's own meeting type, so a forged or stale
  # id can only ever select a location, a provider or a venue the host
  # already offers.
  defp location_attributes(meeting_type_record, %BuildParams{} = params, fallback_video_id) do
    location =
      MeetingTypes.resolve_location(meeting_type_record, %{
        option_id: params.location_option_id,
        phone: params.location_phone,
        video_integration_id: params.location_video_integration_id,
        venue_id: params.location_venue_id
      })

    %{
      location: location.location,
      location_kind: location.location_kind,
      location_option_id: location.location_option_id,
      attendee_phone: location.attendee_phone,
      video_integration_id: video_integration_for(location, fallback_video_id),
      venue_id: location.venue_id,
      address_to_arrange: location.address_to_arrange
    }
  end

  # Where the booking came from: the UTM parameters and referrer captured on
  # the booking page, plus the cookieless key joining this meeting to that
  # page view in analytics. Grouped so the attributes map states the booking
  # itself rather than burying it under eight tracking keys.
  defp source_attribution(%BuildParams{} = params) do
    %{
      utm_source: params.utm_source,
      utm_medium: params.utm_medium,
      utm_campaign: params.utm_campaign,
      utm_content: params.utm_content,
      utm_term: params.utm_term,
      referrer_host: params.referrer_host,
      tracking_params: params.tracking_params,
      visitor_hash: params.visitor_hash
    }
  end

  # A booking on a meeting type requiring manual approval is held rather than
  # confirmed, and carries the clock the host is answering against. Everything
  # else confirms on submission exactly as before, with all three keys nil.
  defp approval_attributes(meeting_type_record, start_datetime) do
    if Approval.required?(meeting_type_record) and not is_nil(start_datetime) do
      requested_at = DateTime.truncate(Clock.utc_now(), :second)

      %{
        status: "awaiting_approval",
        approval_requested_at: requested_at,
        approval_deadline_at:
          Approval.deadline_for(meeting_type_record, requested_at, start_datetime)
      }
    else
      %{status: "confirmed", approval_requested_at: nil, approval_deadline_at: nil}
    end
  end

  # Snapshots host-uploaded meeting-type attachments as plain maps so the
  # calendar event and confirmation email reference a stable file set.
  defp attachments_snapshot(%{attachments: attachments}) do
    Enum.map(attachments, fn a ->
      %{
        "id" => a.id,
        "filename" => a.filename,
        "stored_path" => a.stored_path,
        "content_type" => a.content_type,
        "byte_size" => a.byte_size
      }
    end)
  end

  # Resolves the meeting type record if available and active
  defp resolve_meeting_type_record(meeting_type_id, organizer_user_id) do
    if meeting_type_id && organizer_user_id do
      case MeetingTypes.get_meeting_type(meeting_type_id, organizer_user_id) do
        %{is_active: true} = type -> type
        _other -> nil
      end
    else
      nil
    end
  end

  # Resolves meeting type name, ID, and video integration
  defp resolve_meeting_type_details(meeting_type_record, params, organizer_user_id) do
    case meeting_type_record do
      nil ->
        {"General Meeting", nil, resolve_video_integration_id(params, organizer_user_id)}

      type ->
        resolved_video_id =
          resolve_video_integration_id(params, organizer_user_id) || type.video_integration_id

        {type.name, type.id, resolved_video_id}
    end
  end

  # Gets reminder configuration from meeting type or returns defaults
  defp get_meeting_reminders(meeting_type_record) do
    case meeting_type_record do
      %{reminder_config: reminder_config} when is_list(reminder_config) ->
        Reminders.normalize_reminders(reminder_config)

      _other ->
        [%{value: 30, unit: "minutes"}]
    end
  end

  # A booking-time copy of the action links, kept on the row for readers of
  # the stored columns. Anything shown to a person builds them afresh with
  # `MeetingLinks.for_meeting/1`, since this copy goes stale.
  defp build_meeting_action_urls(meeting_uid, org_username) do
    org_username
    |> MeetingLinks.build(meeting_uid)
    |> Map.put(:meeting_url, nil)
  end

  # The organiser as their profile names them, falling back to the
  # deployment's sender identity (runtime configuration, so read when used).
  defp get_organizer_details(user_id) do
    {sender_name, sender_email} = configured_sender()

    case user_id && ProfileQueries.get_by_user_id(user_id) do
      {:ok, profile} ->
        profile = ProfileQueries.preload_user(profile)
        name = profile.full_name || profile.user.name || sender_name
        email = profile.user.email || sender_email
        {name, email, profile.username}

      _no_profile ->
        {sender_name, sender_email, nil}
    end
  end

  defp configured_sender do
    email_config = Application.get_env(:tymeslot, :email)
    {email_config[:from_name], email_config[:from_email]}
  end

  # Private helper to get calendar integration info for tracking
  defp get_calendar_integration_info(nil), do: {nil, nil}

  defp get_calendar_integration_info(context) do
    case CalendarEvents.get_booking_integration_info(context) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        {integration_id, calendar_path}

      _other ->
        {nil, nil}
    end
  end

  # Once a location has been chosen, it is the only thing that decides
  # whether a room is created and where: an in-person or phone location
  # resolves to no integration, and must *not* inherit the meeting type's,
  # which would open a video room for a meeting nobody is attending online.
  # The meeting-type-level id survives only for ad-hoc bookings, which have
  # no location list to choose from.
  defp video_integration_for(%{location_option_id: nil}, fallback_id), do: fallback_id
  defp video_integration_for(%{video_integration_id: id}, _fallback_id), do: id

  defp resolve_video_integration_id(params, organizer_user_id) do
    video_integration_id =
      case params.video_integration_id do
        id when is_integer(id) ->
          id

        id when is_binary(id) ->
          case Integer.parse(id) do
            {int, ""} -> int
            _other -> nil
          end

        _other ->
          nil
      end

    if is_nil(video_integration_id) or is_nil(organizer_user_id) do
      nil
    else
      case Video.fetch_integration_for_user(video_integration_id, organizer_user_id) do
        {:ok, %{is_active: true}} -> video_integration_id
        _other -> nil
      end
    end
  end

  defp default_locale, do: Locales.booking_default_locale()
end
