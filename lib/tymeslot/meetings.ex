defmodule Tymeslot.Meetings do
  @moduledoc """
  Business logic for managing meetings and appointments.
  Handles the complete meeting creation workflow including database persistence,
  calendar integration, and email notifications.
  """

  require Logger

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{Cancel, Create, Policy, Reschedule}
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Pagination.CursorPage
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker

  # Get Video module dynamically to avoid compile-time warnings with mocks
  @spec video_module() :: module()
  defp video_module do
    Application.get_env(:tymeslot, :video_module, Video)
  end

  @doc """
  Creates a meeting appointment with fresh calendar validation.

  This function performs fresh calendar checks to ensure the slot is still available
  before creating the appointment. This is the recommended function for booking
  as it prevents double-booking conflicts.

  ## Parameters
    - meeting_params: Map containing meeting details
    - validated_form_data: Validated form data from user input

  ## Returns
    - {:ok, meeting} on success
    - {:error, :slot_unavailable} if slot is no longer available
    - {:error, reason} on other failures
  """
  @spec create_appointment_with_validation(map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_appointment_with_validation(meeting_params, validated_form_data) do
    Create.execute(meeting_params, validated_form_data)
  end

  @doc """
  Creates a complete meeting appointment with all associated workflows.

  This function handles:
  1. Database persistence (most important)
  2. Calendar event creation (optional)
  3. Email notification scheduling

  ## Parameters
    - meeting_params: Map containing meeting details
    - validated_form_data: Validated form data from user input

  ## Returns
    - {:ok, meeting} on success
    - {:error, reason} on failure

  DEPRECATED: Use create_appointment_with_validation/2 for new bookings.
  """
  @spec create_appointment(map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_appointment(meeting_params, validated_form_data) do
    Create.execute(meeting_params, validated_form_data, skip_calendar_check: true)
  end

  @doc """
  Parses duration string into minutes.
  """
  @spec parse_duration_minutes(String.t()) :: non_neg_integer()
  def parse_duration_minutes(duration) do
    case duration do
      "15min" -> 15
      "30min" -> 30
      _ -> 30
    end
  end

  @doc """
  Parses time slot string into Time struct.
  """
  @spec parse_time_slot(String.t()) :: Time.t()
  def parse_time_slot(slot_string) do
    TimeSlots.parse_time_slot(slot_string)
  end

  @doc """
  Creates a DateTime safely with timezone fallback.
  """
  @spec create_datetime_safe(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def create_datetime_safe(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} ->
        datetime

      {:error, _reason} ->
        # Fallback to UTC if timezone is invalid
        Logger.warning("Failed to create DateTime in timezone, falling back to UTC",
          timezone: timezone,
          date: date,
          time: time
        )

        DateTime.new!(date, time, "Etc/UTC")
    end
  end

  # Private functions

  @doc """
  Create calendar event asynchronously (don't fail the whole process if this fails).
  """
  @spec create_calendar_event_async(Ecto.Schema.t()) :: :ok
  def create_calendar_event_async(meeting) do
    # Schedule calendar event creation through Oban worker
    case CalendarEventWorker.schedule_calendar_creation(meeting.id) do
      :ok ->
        Logger.info("Calendar event creation scheduled",
          meeting_id: meeting.id,
          uid: meeting.uid
        )

        :ok

      {:error, reason} ->
        Logger.warning("Failed to schedule calendar event creation",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        # Don't fail the meeting creation if scheduling fails
        :ok
    end
  end

  @doc """
  Schedule email notifications via Oban.
  """
  @spec schedule_email_notifications(Ecto.Schema.t()) :: :ok | {:error, any()}
  def schedule_email_notifications(meeting) do
    alias Tymeslot.Notifications.Orchestrator

    case Orchestrator.schedule_meeting_notifications(meeting) do
      {:ok, _} ->
        Logger.info("Meeting notifications scheduled", meeting_id: meeting.id)

      {:error, reason} ->
        Logger.warning("Failed to schedule meeting notifications",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )
    end
  end

  @doc """
  Cancels a meeting including all side effects.

  Delegates to Bookings.Cancel module.
  """
  @spec cancel_meeting(Ecto.Schema.t() | String.t()) :: {:ok, Ecto.Schema.t()} | {:error, atom()}
  def cancel_meeting(meeting_or_uid) do
    Cancel.execute(meeting_or_uid)
  end

  @doc """
  Reschedules an existing meeting.

  Delegates to Bookings.Reschedule module.
  """
  @spec reschedule_meeting(String.t(), map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def reschedule_meeting(meeting_uid, new_params, form_data) do
    Reschedule.execute(meeting_uid, new_params, form_data)
  end

  @doc """
  Cancels a calendar event for a meeting asynchronously.

  DEPRECATED: Use cancel_meeting/1 for complete cancellation workflow.
  """
  @spec cancel_calendar_event(Ecto.Schema.t()) :: :ok
  def cancel_calendar_event(meeting) do
    Logger.info("Scheduling calendar event cancellation",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    # Schedule calendar event deletion through Oban worker
    case CalendarEventWorker.schedule_calendar_deletion(meeting.id) do
      {:ok, _job} ->
        Logger.info("Calendar event deletion scheduled successfully",
          meeting_id: meeting.id,
          uid: meeting.uid
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule calendar event deletion",
          meeting_id: meeting.id,
          uid: meeting.uid,
          reason: inspect(reason)
        )

        # Don't fail the cancellation process if scheduling fails
        :ok
    end
  rescue
    error ->
      Logger.error("Exception while scheduling calendar event cancellation",
        meeting_id: meeting.id,
        error: inspect(error)
      )

      :ok
  end

  # =====================================
  # Video Room Integration Functions
  # =====================================

  @doc """
  Creates a meeting with secure video room integration.

  This is the enhanced version of create_appointment that includes video room creation.
  """
  @spec create_appointment_with_video_room(map(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, atom() | Ecto.Changeset.t()}
  def create_appointment_with_video_room(meeting_params, validated_form_data) do
    Create.execute_with_video_room(meeting_params, validated_form_data)
  end

  @doc """
  Adds a secure video room to an existing meeting.
  """
  @spec add_video_room_to_meeting(String.t()) :: {:ok, MeetingSchema.t()} | {:error, term()}
  def add_video_room_to_meeting(meeting_id) do
    with {:ok, meeting} <- get_meeting_or_error(meeting_id),
         {:ok, user_id} <- get_meeting_organizer_user_id(meeting),
         {:ok, :proceed} <- should_create_video_room(user_id, meeting_id) do
      create_and_attach_video_room(meeting, user_id)
    end
  end

  defp get_meeting_or_error(meeting_id) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:error, :not_found} -> {:error, :meeting_not_found}
      result -> result
    end
  end

  defp get_meeting_organizer_user_id(meeting) do
    # First try to use organizer_user_id if available
    case meeting.organizer_user_id do
      nil ->
        # Fall back to email lookup if no user_id stored
        case UserQueries.get_user_by_email(meeting.organizer_email) do
          {:error, :not_found} ->
            {:error, :organizer_not_found}

          {:ok, user} ->
            {:ok, user.id}
        end

      user_id ->
        {:ok, user_id}
    end
  end

  defp should_create_video_room(user_id, meeting_id) do
    case check_video_provider_type(user_id) do
      {:ok, :none} ->
        Logger.info("Video provider is 'none', skipping video room creation",
          meeting_id: meeting_id
        )

        {:error, :video_disabled}

      {:ok, _provider_type} ->
        {:ok, :proceed}

      error ->
        error
    end
  end

  defp create_and_attach_video_room(meeting, user_id) do
    Logger.info("Adding video room to meeting", meeting_id: meeting.id)

    with {:ok, meeting_context} <- video_module().create_meeting_room(user_id),
         {:ok, video_room_attrs} <- build_video_room_attrs(meeting, meeting_context),
         {:ok, updated_meeting} <- update_meeting_with_video_room(meeting, video_room_attrs) do
      # After attaching the video room, update the calendar event so Google/other calendars
      # include the meeting link in description/location.
      _ = CalendarEventWorker.schedule_calendar_update(updated_meeting.id)
      {:ok, updated_meeting}
    else
      {:error, reason} ->
        Logger.error("Failed to create video room",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp build_video_room_attrs(meeting, meeting_context) do
    with meeting_url <- get_meeting_url_from_context(meeting_context),
         room_id <- video_module().extract_room_id(meeting_context),
         {:ok, organizer_url} <- create_secure_join_url(meeting, meeting_context, "organizer"),
         {:ok, attendee_url} <- create_secure_join_url(meeting, meeting_context, "participant") do
      expiry_time = DateTime.add(meeting.end_time, 1800, :second)

      {:ok,
       %{
         meeting_url: meeting_url,
         location: meeting_url,
         video_room_id: room_id,
         organizer_video_url: organizer_url,
         attendee_video_url: attendee_url,
         video_room_enabled: true,
         video_room_created_at: DateTime.utc_now(),
         video_room_expires_at: expiry_time
       }}
    end
  end

  defp update_meeting_with_video_room(meeting, video_room_attrs) do
    case MeetingQueries.update_meeting(meeting, video_room_attrs) do
      {:ok, updated_meeting} ->
        Logger.info("Video room added successfully",
          meeting_id: meeting.id,
          room_id: video_room_attrs.video_room_id
        )

        {:ok, updated_meeting}

      {:error, changeset} ->
        Logger.error("Failed to update meeting with video room",
          meeting_id: meeting.id,
          errors: inspect(changeset.errors)
        )

        {:error, :database_update_failed}
    end
  end

  defp create_secure_join_url(meeting, meeting_context, role) do
    {participant_name, participant_email} = get_participant_info(meeting, role)

    # Try to create secure URL first
    case create_secure_url(
           meeting_context,
           participant_name,
           participant_email,
           role,
           meeting.start_time
         ) do
      {:ok, url} ->
        {:ok, url}

      {:error, reason} ->
        # Fallback to direct URL on any error
        handle_join_url_error(meeting_context, participant_name, role, reason)
    end
  end

  defp get_participant_info(meeting, "organizer") do
    {meeting.organizer_name, meeting.organizer_email}
  end

  defp get_participant_info(meeting, "participant") do
    {meeting.attendee_name, meeting.attendee_email}
  end

  defp create_secure_url(meeting_context, participant_name, participant_email, role, start_time) do
    video_module().create_join_url(
      meeting_context,
      participant_name,
      participant_email,
      role,
      start_time
    )
  rescue
    error ->
      {:error, error}
  end

  defp handle_join_url_error(meeting_context, participant_name, role, error) do
    room_id = video_module().extract_room_id(meeting_context)

    Logger.error("Failed to create secure join URL",
      room_id: room_id,
      role: role,
      error: inspect(error)
    )

    fallback_url = create_direct_join_url_fallback(room_id, participant_name)
    {:ok, fallback_url}
  end

  # Helper functions for video integration
  defp get_meeting_url_from_context(meeting_context) do
    meeting_context.room_data[:meeting_url] ||
      meeting_context.room_data["meeting_url"] ||
      meeting_context.room_data[:room_id] ||
      meeting_context.room_data["room_id"]
  end

  defp check_video_provider_type(user_id) do
    case VideoIntegrationQueries.get_default_for_user(user_id) do
      {:ok, integration} ->
        provider_type = String.to_existing_atom(integration.provider)
        {:ok, provider_type}

      {:error, :not_found} ->
        {:error, "No video integration configured"}
    end
  end

  defp get_meeting_context_from_room_id(room_id) do
    # Create a minimal context for backward compatibility
    %{
      provider_type: :mirotalk,
      room_data: %{room_id: room_id, meeting_url: room_id},
      provider_module: Tymeslot.Integrations.Video.Providers.MiroTalkProvider
    }
  end

  defp create_direct_join_url_fallback(room_id, participant_name) do
    # Fallback to direct URL creation for backward compatibility
    case video_module().create_join_url(
           get_meeting_context_from_room_id(room_id),
           participant_name,
           "",
           "participant",
           DateTime.utc_now()
         ) do
      {:ok, url} ->
        url

      {:error, _} ->
        # Ensure participant name is URL-encoded
        query = URI.encode_query(%{name: participant_name})
        "#{room_id}?#{query}"
    end
  end

  # =====================================
  # Meeting List and Query Functions
  # =====================================

  @doc """
  Lists all upcoming meetings.
  """
  @spec list_upcoming_meetings() :: [Ecto.Schema.t()]
  def list_upcoming_meetings do
    MeetingQueries.list_upcoming_meetings()
  end

  @doc """
  Lists upcoming meetings for a specific user.
  """
  @spec list_upcoming_meetings_for_user(String.t()) :: [Ecto.Schema.t()]
  def list_upcoming_meetings_for_user(user_email) do
    # Use the existing query function but keep business logic here
    # The query function handles the database filtering efficiently
    MeetingQueries.list_upcoming_meetings_for_user(user_email)
  end

  @doc """
  Lists all past meetings.
  """
  @spec list_past_meetings() :: [Ecto.Schema.t()]
  def list_past_meetings do
    all_meetings = MeetingQueries.list_meetings()

    Enum.filter(all_meetings, fn meeting ->
      DateTime.compare(meeting.end_time, DateTime.utc_now()) == :lt
    end)
  end

  @doc """
  Lists past meetings for a specific user.
  """
  @spec list_past_meetings_for_user(String.t()) :: [Ecto.Schema.t()]
  def list_past_meetings_for_user(user_email) do
    # Use the existing query function but keep business logic here
    MeetingQueries.list_past_meetings_for_user(user_email)
  end

  @doc """
  Sends a reschedule request email for a meeting.
  """
  @spec send_reschedule_request(Ecto.Schema.t()) :: :ok | {:error, atom()}
  def send_reschedule_request(meeting) do
    # First check if rescheduling is allowed by policy
    case Policy.can_reschedule_meeting?(meeting) do
      :ok ->
        # Update the meeting status to reschedule_requested
        update_and_send_reschedule_request(meeting)

      {:error, reason} ->
        Logger.warning("Reschedule request blocked by policy",
          meeting_id: meeting.id,
          reason: reason
        )

        {:error, reason}
    end
  end

  defp update_and_send_reschedule_request(meeting) do
    case MeetingQueries.update_meeting(meeting, %{status: "reschedule_requested"}) do
      {:ok, updated_meeting} ->
        # Then queue the email
        job_params = %{
          "action" => "send_reschedule_request",
          "meeting_id" => updated_meeting.id
        }

        case Oban.insert(EmailWorker.new(job_params, queue: :emails, priority: 1)) do
          {:ok, _job} ->
            Logger.info("Reschedule request email job queued",
              meeting_id: updated_meeting.id,
              status: updated_meeting.status
            )

            :ok

          {:error, reason} ->
            Logger.error("Failed to queue reschedule request email",
              meeting_id: updated_meeting.id,
              error: inspect(reason)
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to update meeting status for reschedule request",
          meeting_id: meeting.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Lists all cancelled meetings for a specific user.
  """
  @spec list_cancelled_meetings_for_user(String.t()) :: [Ecto.Schema.t()]
  def list_cancelled_meetings_for_user(user_email) do
    # Use the existing query function but keep business logic here
    MeetingQueries.list_cancelled_meetings_for_user(user_email)
  end

  @doc """
  Returns meetings that need reminder emails sent.
  This finds meetings that are:
  - Starting within the next hour
  - Have reminder_email_sent = false
  - Are in confirmed status

  ## Examples

      iex> meetings_needing_reminders()
      [%Meeting{}, ...]

  """
  @spec meetings_needing_reminders() :: [Ecto.Schema.t()]
  def meetings_needing_reminders do
    # Business logic: meetings needing reminders are those starting within next hour
    now = DateTime.utc_now()
    one_hour_from_now = DateTime.add(now, 1, :hour)
    # The query function handles the database filtering efficiently
    MeetingQueries.list_meetings_needing_reminders(now, one_hour_from_now)
  end

  @doc """
  Cursor-based pagination for a user's meetings.

  Options:
  - :per_page (default 20)
  - :status (e.g., "confirmed")
  - :time_filter (:upcoming | :past | nil)
  - :after (cursor string produced by this function)

  Returns {:ok, %CursorPage{}} | {:error, :invalid_cursor}
  """
  @spec list_user_meetings_cursor_page(String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page(user_email, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    status = Keyword.get(opts, :status)
    time_filter = Keyword.get(opts, :time_filter)
    cursor = Keyword.get(opts, :after)

    case decode_cursor_opt(cursor) do
      :no_cursor ->
        items =
          list_user_meetings_internal(user_email,
            per_page: per_page,
            status: status,
            time_filter: time_filter
          )

        {:ok, build_cursor_page(items, per_page)}

      {:ok, %{after_start: after_start, after_id: after_id}} ->
        items =
          list_user_meetings_internal(user_email,
            per_page: per_page,
            status: status,
            time_filter: time_filter,
            after_start: after_start,
            after_id: after_id
          )

        {:ok, build_cursor_page(items, per_page)}

      {:error, :invalid_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  defp list_user_meetings_internal(user_email, opts) do
    per_page = Keyword.get(opts, :per_page, 20)
    status = Keyword.get(opts, :status)
    time_filter = Keyword.get(opts, :time_filter)
    after_start = Keyword.get(opts, :after_start)
    after_id = Keyword.get(opts, :after_id)

    MeetingQueries.list_meetings_for_user_paginated_cursor(user_email,
      per_page: per_page,
      status: status,
      time_filter: time_filter,
      after_start: after_start,
      after_id: after_id
    )
  end

  @doc """
  Cursor-based pagination by user_id. Resolves the email internally to avoid coupling callers to email.
  """
  @spec list_user_meetings_cursor_page_by_id(integer(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page_by_id(user_id, opts \\ []) do
    case UserQueries.get_user(user_id) do
      {:ok, user} ->
        list_user_meetings_cursor_page(user.email, opts)

      {:error, :not_found} ->
        {:ok,
         %CursorPage{
           items: [],
           next_cursor: nil,
           prev_cursor: nil,
           page_size: Keyword.get(opts, :per_page, 20),
           has_more: false
         }}
    end
  end

  defp decode_cursor_opt(nil), do: :no_cursor
  defp decode_cursor_opt(""), do: :no_cursor

  defp decode_cursor_opt(cursor) when is_binary(cursor) do
    CursorPage.decode_cursor(cursor)
  end

  defp build_cursor_page(items, per_page) do
    has_more = length(items) == per_page

    next_cursor =
      case List.last(items) do
        nil -> nil
        last -> CursorPage.encode_cursor(%{after_start: last.start_time, after_id: last.id})
      end

    %CursorPage{
      items: items,
      next_cursor: next_cursor,
      prev_cursor: nil,
      page_size: per_page,
      has_more: has_more
    }
  end

  @doc """
  Gets a single meeting by ID.
  Raises if not found.
  """
  @spec get_meeting!(String.t()) :: MeetingSchema.t()
  def get_meeting!(id) do
    case MeetingQueries.get_meeting(id) do
      {:ok, meeting} ->
        meeting

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: Tymeslot.DatabaseSchemas.MeetingSchema
    end
  end
end
