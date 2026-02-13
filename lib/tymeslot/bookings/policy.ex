defmodule Tymeslot.Bookings.Policy do
  @moduledoc """
  Business rules and policies for bookings.
  Pure functions that define what is allowed.
  """
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.{ReminderUtils, TimezoneUtils}
  alias TymeslotWeb.Endpoint

  require Logger

  @doc """
  Gets scheduling configuration with defaults.
  Now accepts an optional organizer_user_id to get user-specific settings.
  """
  @spec scheduling_config(integer() | nil) :: %{
          required(:buffer_minutes) => integer(),
          required(:min_advance_hours) => integer(),
          required(:max_advance_booking_days) => integer(),
          required(:owner_timezone) => String.t()
        }
  def scheduling_config(organizer_user_id \\ nil) do
    # Get timezone and settings from user profile
    {owner_timezone, buffer_minutes, advance_booking_days, min_advance_hours} =
      case organizer_user_id do
        nil ->
          # Fallback when no user specified
          {"Europe/Kyiv", 15, 90, 3}

        user_id ->
          settings = Profiles.get_profile_settings(user_id)

          {settings.timezone, settings.buffer_minutes, settings.advance_booking_days,
           settings.min_advance_hours}
      end

    %{
      buffer_minutes: buffer_minutes,
      min_advance_hours: min_advance_hours,
      max_advance_booking_days: advance_booking_days,
      owner_timezone: owner_timezone
    }
  end

  @doc """
  Builds meeting attributes from parameters and form data.
  Pure transformation function.
  """
  @spec build_meeting_attributes(map()) :: map()
  def build_meeting_attributes(params) do
    meeting_uid = params.meeting_uid
    organizer_user_id = Map.get(params, :organizer_user_id)
    meeting_type_id = Map.get(params, :meeting_type_id)
    form_data = params.form_data

    # Resolve meeting type if ID provided
    meeting_type_record = resolve_meeting_type_record(meeting_type_id, organizer_user_id)

    # Get organizer details from profile if available
    {org_name, org_email, org_username} = get_organizer_details(organizer_user_id)

    # Resolve attendee timezone
    config = scheduling_config(organizer_user_id)
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
        description: form_data["message"] || "",
        start_time: params.start_datetime,
        end_time: params.end_datetime,
        duration: params.duration_minutes,
        location: "To be determined",
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
        attendee_timezone: TimezoneUtils.normalize_timezone(user_timezone),
        status: "confirmed",
        reminders: reminders
      },
      build_meeting_action_urls(meeting_uid, org_username)
    )
  end

  # Resolves the meeting type record if available and active
  defp resolve_meeting_type_record(meeting_type_id, organizer_user_id) do
    if meeting_type_id && organizer_user_id do
      case MeetingTypes.get_meeting_type(meeting_type_id, organizer_user_id) do
        %{is_active: true} = type -> type
        _ -> nil
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
      %{reminder_config: reminder_config} when not is_nil(reminder_config) ->
        ReminderUtils.normalize_reminders(reminder_config)

      _ ->
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
      _ -> false
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
  @spec can_cancel_meeting?(map()) :: :ok | {:error, String.t()}
  def can_cancel_meeting?(meeting) do
    cond do
      meeting.status == "cancelled" ->
        {:error, "Meeting is already cancelled"}

      meeting.status == "completed" ->
        {:error, "Cannot cancel a completed meeting"}

      meeting_is_current?(meeting) ->
        Logger.info(
          "Blocked cancellation for meeting #{meeting.uid}: meeting has already started"
        )

        {:error, "Cannot cancel a meeting that has already started"}

      meeting_is_past?(meeting) ->
        Logger.info(
          "Blocked cancellation for meeting #{meeting.uid}: meeting has already occurred"
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
  @spec can_reschedule_meeting?(map()) :: :ok | {:error, String.t()}
  def can_reschedule_meeting?(meeting) do
    cond do
      meeting.status == "cancelled" ->
        {:error, "Cannot reschedule a cancelled meeting"}

      meeting.status == "completed" ->
        {:error, "Cannot reschedule a completed meeting"}

      meeting_is_current?(meeting) ->
        Logger.info("Blocked reschedule for meeting #{meeting.uid}: meeting has already started")
        {:error, "Cannot reschedule a meeting that has already started"}

      meeting_is_past?(meeting) ->
        Logger.info("Blocked reschedule for meeting #{meeting.uid}: meeting has already occurred")
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
          required(:end_time) => DateTime.t()
        }) :: boolean()
  def meeting_is_current?(%{start_time: start_time, end_time: end_time}) do
    now = DateTime.utc_now()
    DateTime.compare(start_time, now) != :gt && DateTime.compare(end_time, now) == :gt
  end

  @doc """
  Checks if a meeting is in the past.
  Pure function that compares meeting end time with current UTC time.
  """
  @spec meeting_is_past?(map()) :: boolean()
  def meeting_is_past?(%{end_time: end_time}) do
    DateTime.compare(end_time, DateTime.utc_now()) == :lt
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
    case Calendar.get_booking_integration_info(context) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        {integration_id, calendar_path}

      _ ->
        {nil, nil}
    end
  end

  defp resolve_video_integration_id(params, organizer_user_id) do
    video_integration_id =
      case Map.get(params, :video_integration_id) do
        id when is_integer(id) ->
          id

        id when is_binary(id) ->
          case Integer.parse(id) do
            {int, ""} -> int
            _ -> nil
          end

        _ ->
          nil
      end

    if is_nil(video_integration_id) or is_nil(organizer_user_id) do
      nil
    else
      case VideoIntegrationQueries.get_for_user(video_integration_id, organizer_user_id) do
        {:ok, %{is_active: true}} -> video_integration_id
        _ -> nil
      end
    end
  end

  @doc """
  Gets the application base URL based on configuration.
  """
  @spec app_url() :: String.t()
  def app_url do
    Endpoint.url()
  end
end
