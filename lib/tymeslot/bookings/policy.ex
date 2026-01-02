defmodule Tymeslot.Bookings.Policy do
  @moduledoc """
  Business rules and policies for bookings.
  Pure functions that define what is allowed.
  """
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.TimezoneUtils
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
    start_datetime = params.start_datetime
    end_datetime = params.end_datetime
    duration_minutes = params.duration_minutes
    form_data = params.form_data
    organizer_user_id = Map.get(params, :organizer_user_id)

    # Get organizer details from profile if available
    {org_name, org_email, org_username} = get_organizer_details(organizer_user_id)

    # Ensure we always have a timezone for the attendee
    # Fallback to organizer's timezone if not provided (e.g., browser detection failed)
    config = scheduling_config(organizer_user_id)
    user_timezone = params.user_timezone || config.owner_timezone

    # Get calendar integration info
    {calendar_integration_id, calendar_path} = get_calendar_integration_info(organizer_user_id)

    %{
      uid: meeting_uid,
      title: "Meeting with #{form_data["name"]}",
      summary: "Meeting with #{form_data["name"]}",
      description: form_data["message"] || "",
      start_time: start_datetime,
      end_time: end_datetime,
      duration: duration_minutes,
      location: "To be determined",
      meeting_type: "General Meeting",

      # Organizer details (from profile or config)
      organizer_name: org_name,
      organizer_email: org_email,
      organizer_title: nil,
      organizer_user_id: organizer_user_id,

      # Calendar integration tracking
      calendar_integration_id: calendar_integration_id,
      calendar_path: calendar_path,

      # Attendee details
      attendee_name: form_data["name"],
      attendee_email: form_data["email"],
      attendee_message: form_data["message"],
      attendee_phone: nil,
      attendee_company: nil,
      # Always normalize and ensure we have a valid timezone
      attendee_timezone: TimezoneUtils.normalize_timezone(user_timezone),

      # URLs
      view_url: build_meeting_url(meeting_uid, "", org_username),
      reschedule_url: build_meeting_url(meeting_uid, "/reschedule", org_username),
      cancel_url: build_meeting_url(meeting_uid, "/cancel", org_username),
      meeting_url: nil,

      # Status
      status: "confirmed"
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

  defp get_calendar_integration_info(user_id) do
    case Calendar.get_booking_integration_info(user_id) do
      {:ok, %{integration_id: integration_id, calendar_path: calendar_path}} ->
        {integration_id, calendar_path}

      _ ->
        {nil, nil}
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
