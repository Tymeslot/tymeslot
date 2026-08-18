defmodule Tymeslot.Bookings.Policy do
  @moduledoc """
  Business rules and policies for bookings.

  Two kinds of function live here. The verdict predicates
  (`can_cancel_meeting?/1`, `can_reschedule_meeting?/1`, …) are pure. The
  attribute assembly (`build_meeting_attributes/1`, `scheduling_config/2`) is
  not: it resolves the profile, the schedule, the video integration and the
  meeting type, and so performs database reads. Callers that need purity should
  reach for the predicates, not the assembler.
  """
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Bookings.BuildParams
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Locales
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Utils.UrlBuilder

  require Logger

  @doc """
  Scheduling policy for a booking: buffer, minimum notice, advance window and
  the organiser's timezone.

  The policy comes from the schedule the meeting type is booked against, so
  server-side validation applies exactly the rules the offered slots were
  computed from. A nil meeting type resolves the organiser's default schedule.
  """
  @spec scheduling_config(integer() | nil, map() | nil) :: %{
          required(:buffer_minutes) => integer(),
          required(:min_advance_hours) => integer(),
          required(:max_advance_booking_days) => integer(),
          required(:owner_timezone) => String.t()
        }
  def scheduling_config(organizer_user_id \\ nil, meeting_type \\ nil)

  def scheduling_config(nil, _meeting_type) do
    Map.put(policy_values(nil), :owner_timezone, Profiles.get_default_timezone())
  end

  def scheduling_config(organizer_user_id, meeting_type) do
    settings = Profiles.get_profile_settings(organizer_user_id)

    organizer_user_id
    |> resolve_schedule(meeting_type)
    |> policy_values()
    |> Map.put(:owner_timezone, settings.timezone)
  end

  # `max_advance_booking_days` is this map's name for the schedule's
  # `advance_booking_days`; every other key is carried through unrenamed.
  defp policy_values(schedule) do
    %{
      buffer_minutes: Schedules.policy(schedule, :buffer_minutes),
      min_advance_hours: Schedules.policy(schedule, :min_advance_hours),
      max_advance_booking_days: Schedules.policy(schedule, :advance_booking_days)
    }
  end

  defp resolve_schedule(_organizer_user_id, %{} = meeting_type) do
    Schedules.resolve_for_meeting_type(meeting_type)
  end

  defp resolve_schedule(organizer_user_id, _meeting_type) do
    case ProfileQueries.get_by_user_id(organizer_user_id) do
      {:ok, profile} -> Schedules.get_default(profile.id)
      {:error, :not_found} -> nil
    end
  end

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
          required(:meeting_type) => String.t(),
          required(:meeting_type_id) => integer() | nil,
          required(:organizer_name) => String.t(),
          required(:organizer_email) => String.t(),
          required(:organizer_title) => String.t() | nil,
          required(:organizer_user_id) => integer() | nil,
          required(:calendar_integration_id) => integer() | nil,
          required(:calendar_path) => String.t() | nil,
          required(:video_integration_id) => integer() | nil,
          required(:attendee_name) => String.t(),
          required(:attendee_email) => String.t(),
          required(:attendee_message) => String.t() | nil,
          required(:attendee_phone) => String.t() | nil,
          required(:attendee_company) => String.t() | nil,
          required(:attendee_timezone) => String.t(),
          required(:attendee_locale) => String.t(),
          required(:status) => String.t(),
          required(:reminders) => [reminder()],
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

  @typedoc "A meeting record with the fields required by the policy checks."
  @type meeting_record :: %{
          required(:status) => String.t(),
          required(:uid) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          optional(atom()) => term()
        }

  @doc """
  Builds meeting attributes from parameters and form data.

  Resolves the organiser's profile, schedule and integrations along the way, so
  this reads from the database rather than being a pure transformation.
  """
  # Dialyzer can verify the typed `BuildParams.t()` input, but it cannot prove
  # the precise field types of the returned map: this is a pure data-shuffler
  # whose values flow straight from struct/schema fields and the attendee's
  # form data (`form_data["name"]` etc. are inherently `term()`), so the success
  # typing widens every output field to `any()`. The `meeting_attributes` spec
  # is retained as the authoritative documentation of the result shape; the
  # contract check is disabled rather than gutting that type to `term()`.
  @dialyzer {:no_contracts, build_meeting_attributes: 1}
  @spec build_meeting_attributes(BuildParams.t()) :: meeting_attributes()
  def build_meeting_attributes(%BuildParams{} = params) do
    meeting_uid = params.meeting_uid
    organizer_user_id = params.organizer_user_id
    meeting_type_id = params.meeting_type_id
    form_data = params.form_data

    # Resolve meeting type if ID provided
    meeting_type_record = resolve_meeting_type_record(meeting_type_id, organizer_user_id)

    # Get organizer details from profile if available
    {org_name, org_email, org_username} = get_organizer_details(organizer_user_id)

    # Resolve attendee timezone
    config = scheduling_config(organizer_user_id, meeting_type_record)
    user_timezone = params.user_timezone || config.owner_timezone

    # Get calendar integration info
    {calendar_integration_id, calendar_path} =
      get_calendar_integration_info(meeting_type_record || organizer_user_id)

    # Resolve meeting type details
    {meeting_type_name, resolved_meeting_type_id, video_integration_id} =
      resolve_meeting_type_details(meeting_type_record, params, organizer_user_id)

    # Get reminder configuration
    reminders = get_meeting_reminders(meeting_type_record)

    # Build complete meeting attributes map
    Map.merge(
      %{
        uid: meeting_uid,
        title: "#{meeting_type_name} with #{form_data["name"]}",
        summary: "#{meeting_type_name} with #{form_data["name"]}",
        description: (meeting_type_record && meeting_type_record.description) || "",
        start_time: params.start_datetime,
        end_time: params.end_datetime,
        duration: params.duration_minutes,
        location: nil,
        meeting_type: meeting_type_name,
        meeting_type_id: resolved_meeting_type_id,
        organizer_name: org_name,
        organizer_email: org_email,
        organizer_title: nil,
        organizer_user_id: organizer_user_id,
        calendar_integration_id: calendar_integration_id,
        calendar_path: calendar_path,
        video_integration_id: video_integration_id,
        attendee_name: form_data["name"],
        attendee_email: form_data["email"],
        attendee_message: form_data["message"],
        attendee_phone: nil,
        attendee_company: nil,
        attendee_timezone: Timezones.normalize(user_timezone),
        attendee_locale: params.attendee_locale || default_locale(),
        status: "confirmed",
        reminders: reminders,
        show_as_free: (meeting_type_record && meeting_type_record.show_as_free) || false,
        attachments_snapshot: attachments_snapshot(meeting_type_record),
        custom_fields_snapshot: params.custom_fields_snapshot,
        custom_field_answers: params.custom_field_answers,
        utm_source: params.utm_source,
        utm_medium: params.utm_medium,
        utm_campaign: params.utm_campaign,
        utm_content: params.utm_content,
        utm_term: params.utm_term,
        referrer_host: params.referrer_host,
        tracking_params: params.tracking_params,
        visitor_hash: params.visitor_hash
      },
      build_meeting_action_urls(meeting_uid, org_username)
    )
  end

  # Snapshots host-uploaded meeting-type attachments as plain maps so the
  # calendar event and confirmation email reference a stable file set.
  defp attachments_snapshot(%{attachments: attachments}) when is_list(attachments) do
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

  defp attachments_snapshot(_meeting_type), do: []

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
        ReminderUtils.normalize_reminders(reminder_config)

      _other ->
        [%{value: 30, unit: "minutes"}]
    end
  end

  # Builds URLs for meeting actions (view, reschedule, cancel)
  defp build_meeting_action_urls(meeting_uid, org_username) do
    %{
      view_url: build_meeting_url(meeting_uid, "", org_username),
      reschedule_url: build_meeting_url(meeting_uid, "/reschedule", org_username),
      cancel_url: build_meeting_url(meeting_uid, "/cancel", org_username),
      meeting_url: nil
    }
  end

  @doc """
  Determines if a calendar check failure should block booking.

  Some calendar failures are recoverable (network issues),
  while others should block the booking attempt.
  """
  @spec should_block_on_calendar_failure?(term()) :: boolean()
  def should_block_on_calendar_failure?(reason) do
    case reason do
      :slot_unavailable -> true
      :calendar_fetch_failed -> false
      _other -> false
    end
  end

  @doc """
  Gets the organizer name from configuration.
  """
  @spec organizer_name() :: String.t()
  def organizer_name do
    Application.get_env(:tymeslot, :email)[:from_name]
  end

  @doc """
  Gets the organizer email from configuration.
  """
  @spec organizer_email() :: String.t()
  def organizer_email do
    Application.get_env(:tymeslot, :email)[:from_email]
  end

  @doc """
  Determines if a meeting can be cancelled.
  Checks both status and time constraints.
  """
  @spec can_cancel_meeting?(meeting_record()) :: :ok | {:error, String.t()}
  def can_cancel_meeting?(meeting) do
    cond do
      meeting.status == "cancelled" ->
        {:error, "Meeting is already cancelled"}

      meeting.status == "completed" ->
        {:error, "Cannot cancel a completed meeting"}

      meeting_is_current?(meeting) ->
        Logger.info("Blocked cancellation: meeting has already started",
          meeting_uid: meeting.uid
        )

        {:error, "Cannot cancel a meeting that has already started"}

      meeting_is_past?(meeting) ->
        Logger.info("Blocked cancellation: meeting has already occurred",
          meeting_uid: meeting.uid
        )

        {:error, "Cannot cancel a meeting that has already occurred"}

      true ->
        :ok
    end
  end

  @doc """
  Determines if a meeting can be rescheduled.
  Checks both status and time constraints.
  """
  @spec can_reschedule_meeting?(meeting_record()) :: :ok | {:error, String.t()}
  def can_reschedule_meeting?(meeting) do
    cond do
      meeting.status == "cancelled" ->
        {:error, "Cannot reschedule a cancelled meeting"}

      meeting.status == "completed" ->
        {:error, "Cannot reschedule a completed meeting"}

      meeting_is_current?(meeting) ->
        Logger.info("Blocked reschedule: meeting has already started", meeting_uid: meeting.uid)
        {:error, "Cannot reschedule a meeting that has already started"}

      meeting_is_past?(meeting) ->
        Logger.info("Blocked reschedule: meeting has already occurred", meeting_uid: meeting.uid)
        {:error, "Cannot reschedule a meeting that has already occurred"}

      true ->
        :ok
    end
  end

  @doc """
  Checks if a meeting is currently happening.
  Pure function that compares meeting times with current UTC time.
  """
  @spec meeting_is_current?(%{
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          optional(atom()) => term()
        }) :: boolean()
  def meeting_is_current?(%{start_time: start_time, end_time: end_time}) do
    now = Clock.utc_now()
    DateTime.compare(start_time, now) != :gt && DateTime.compare(end_time, now) == :gt
  end

  @doc """
  Checks if a meeting is in the past.
  Pure function that compares meeting end time with current UTC time.
  """
  @spec meeting_is_past?(%{required(:end_time) => DateTime.t(), optional(atom()) => term()}) ::
          boolean()
  def meeting_is_past?(%{end_time: end_time}) do
    DateTime.compare(end_time, Clock.utc_now()) == :lt
  end

  # Private functions

  defp build_meeting_url(meeting_uid, path, username) do
    if username do
      app_url() <> "/#{username}/meeting/#{meeting_uid}#{path}"
    else
      # Fallback to old URL structure if no username available
      app_url() <> "/meeting/#{meeting_uid}#{path}"
    end
  end

  # Private helper to get organizer details from profile or fallback to config
  defp get_organizer_details(nil), do: {organizer_name(), organizer_email(), nil}

  defp get_organizer_details(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} ->
        {organizer_name(), organizer_email(), nil}

      {:ok, profile} ->
        profile = ProfileQueries.preload_user(profile)
        name = profile.full_name || profile.user.name || organizer_name()
        email = profile.user.email || organizer_email()
        username = profile.username
        {name, email, username}
    end
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

  @doc """
  Gets the application base URL based on configuration.
  """
  @spec app_url() :: String.t()
  defdelegate app_url, to: UrlBuilder, as: :base_url

  @doc """
  Builds the public accept/decline RSVP URLs for a guest's token.
  """
  @spec guest_rsvp_urls(String.t()) :: %{accept_url: String.t(), decline_url: String.t()}
  def guest_rsvp_urls(token) when is_binary(token) do
    %{
      accept_url: app_url() <> "/guest/#{token}/accept",
      decline_url: app_url() <> "/guest/#{token}/decline"
    }
  end

  defp default_locale, do: Locales.default_locale()
end
