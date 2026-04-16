defmodule Tymeslot.Bookings.CreateAdHoc do
  @moduledoc """
  Creates ad-hoc meetings directly from the dashboard calendar.

  Unlike `Bookings.Create`, this does not require a meeting type or booking form.
  The organiser provides attendee details and timing directly, and the system
  creates a full Meeting record with calendar sync, email notifications, and
  optional video room provisioning.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoRoomWorker
  alias TymeslotWeb.Endpoint

  @type params :: %{
          required(:title) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:attendee_name) => String.t(),
          required(:attendee_email) => String.t(),
          required(:organizer_user_id) => pos_integer(),
          optional(:attendee_timezone) => String.t(),
          optional(:calendar_integration_id) => pos_integer() | nil,
          optional(:calendar_path) => String.t() | nil,
          optional(:video_integration_id) => pos_integer() | nil
        }

  @spec execute(params()) ::
          {:ok, Tymeslot.Meetings.MeetingSchema.t()} | {:error, String.t()}
  def execute(params) do
    with :ok <- validate(params) do
      params
      |> build_meeting_attrs()
      |> run_transaction()
    end
  end

  defp validate(params) do
    cond do
      blank?(params[:title]) ->
        {:error, "Title is required"}

      blank?(params[:attendee_name]) ->
        {:error, "Attendee name is required"}

      blank?(params[:attendee_email]) ->
        {:error, "Attendee email is required"}

      DateTime.compare(params.end_time, params.start_time) != :gt ->
        {:error, "End time must be after start time"}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_other), do: false

  defp build_meeting_attrs(params) do
    uid = UUID.generate()
    {org_name, org_email, org_username} = get_organizer_details(params.organizer_user_id)
    duration = DateTime.diff(params.end_time, params.start_time, :minute)

    %{
      uid: uid,
      title: params.title,
      summary: params.title,
      description: "",
      start_time: params.start_time,
      end_time: params.end_time,
      duration: duration,
      location: "To be determined",
      meeting_type: params.title,
      meeting_type_id: nil,
      organizer_name: org_name,
      organizer_email: org_email,
      organizer_user_id: params.organizer_user_id,
      calendar_integration_id: params[:calendar_integration_id],
      calendar_path: params[:calendar_path],
      video_integration_id: params[:video_integration_id],
      attendee_name: params.attendee_name,
      attendee_email: params.attendee_email,
      attendee_message: nil,
      attendee_timezone: params[:attendee_timezone] || "Etc/UTC",
      attendee_locale: "en",
      status: "confirmed",
      view_url: build_meeting_url(uid, "", org_username),
      reschedule_url: build_meeting_url(uid, "/reschedule", org_username),
      cancel_url: build_meeting_url(uid, "/cancel", org_username),
      meeting_url: nil
    }
  end

  defp run_transaction(meeting_attrs) do
    result =
      Repo.transaction(fn ->
        with {:ok, meeting} <- create_meeting(meeting_attrs),
             {:ok, _job} <- schedule_calendar_job(meeting) do
          handle_side_effects(meeting, meeting_attrs[:video_integration_id])
          meeting
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    map_result(result)
  end

  defp create_meeting(attrs) do
    case Scheduling.create_meeting_with_conflict_check(attrs) do
      {:ok, meeting} -> {:ok, meeting}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_calendar_job(meeting) do
    if meeting.calendar_integration_id do
      CalendarJobs.schedule_job(meeting, "create")
    else
      {:ok, :skipped}
    end
  end

  defp handle_side_effects(meeting, video_integration_id)
       when is_integer(video_integration_id) do
    case VideoRoomWorker.schedule_video_room_creation_with_emails(meeting.id) do
      :ok -> :ok
      {:error, _error} -> schedule_notifications(meeting)
    end
  end

  defp handle_side_effects(meeting, _no_video) do
    schedule_notifications(meeting)
  end

  defp schedule_notifications(meeting) do
    result =
      case Events.meeting_created(meeting) do
        {:ok, _result} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to schedule notifications for ad-hoc meeting",
            meeting_id: meeting.id,
            error: inspect(reason)
          )

          :ok
      end

    # After event creation, also route the attendee-facing calendar invitation
    # through AttendeeNotifications so last_notified_state / ical_sequence are
    # initialised correctly.
    {:ok, _job} = AttendeeNotifications.event_created(meeting, attendees_for(meeting))

    result
  end

  defp attendees_for(%{attendee_email: email}) when is_binary(email) and email != "" do
    [%{email: email}]
  end

  defp attendees_for(_meeting), do: []

  defp map_result({:ok, meeting}), do: {:ok, meeting}
  defp map_result({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp map_result({:error, _reason}), do: {:error, "Failed to create meeting"}

  defp get_organizer_details(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} ->
        {fallback_name(), fallback_email(), nil}

      {:ok, profile} ->
        profile = ProfileQueries.preload_user(profile)
        name = profile.full_name || profile.user.name || fallback_name()
        email = profile.user.email || fallback_email()
        username = profile.username
        {name, email, username}
    end
  end

  defp build_meeting_url(uid, path, username) do
    base = Endpoint.url()

    if username do
      "#{base}/#{username}/meeting/#{uid}#{path}"
    else
      "#{base}/meeting/#{uid}#{path}"
    end
  end

  defp fallback_name do
    Application.get_env(:tymeslot, :email)[:from_name] || "Organiser"
  end

  defp fallback_email do
    Application.get_env(:tymeslot, :email)[:from_email] || "noreply@tymeslot.app"
  end
end
