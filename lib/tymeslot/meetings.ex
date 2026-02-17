defmodule Tymeslot.Meetings do
  @moduledoc """
  Business logic for managing meetings and appointments.
  Handles the complete meeting creation workflow including database persistence,
  calendar integration, and email notifications.
  """

  require Logger

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{Cancel, Create, Reschedule, RescheduleRequest}
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Meetings.{Queries, VideoRooms}
  alias Tymeslot.Pagination.CursorPage
  alias Tymeslot.Workers.CalendarEventWorker

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
      _other -> 30
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
      {:ok, _result} ->
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

  This is a high-level operation that ensures the meeting exists and the video
  room is successfully attached. It handles logging and error translation
  for the web layer.
  """
  @spec add_video_room_to_meeting(String.t()) :: {:ok, MeetingSchema.t()} | {:error, term()}
  def add_video_room_to_meeting(meeting_id) do
    Logger.info("Request to add video room to meeting", meeting_id: meeting_id)

    case VideoRooms.add_video_room_to_meeting(meeting_id) do
      {:ok, meeting} ->
        Logger.info("Successfully added video room", meeting_id: meeting_id)
        {:ok, meeting}

      {:error, :meeting_not_found} ->
        Logger.warning("Attempted to add video room to non-existent meeting",
          meeting_id: meeting_id
        )

        {:error, :meeting_not_found}

      {:error, reason} = error ->
        Logger.error("Failed to add video room", meeting_id: meeting_id, reason: inspect(reason))
        error
    end
  end

  # =====================================
  # Meeting List and Query Functions
  # =====================================

  @doc """
  Lists all upcoming meetings.
  """
  @spec list_upcoming_meetings() :: [MeetingSchema.t()]
  def list_upcoming_meetings do
    Queries.list_upcoming_meetings()
  end

  @doc """
  Lists upcoming meetings for a specific user with a limit.
  """
  @spec list_upcoming_meetings_for_user(String.t(), integer()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email, limit) do
    Queries.list_upcoming_meetings_for_user(user_email, limit)
  end

  @doc """
  Lists all upcoming meetings for a specific user.
  """
  @spec list_upcoming_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email) do
    Queries.list_upcoming_meetings_for_user(user_email)
  end

  @doc """
  Lists all past meetings.
  """
  @spec list_past_meetings() :: [MeetingSchema.t()]
  def list_past_meetings do
    Queries.list_past_meetings()
  end

  @doc """
  Lists past meetings for a specific user.
  """
  @spec list_past_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_past_meetings_for_user(user_email) do
    Queries.list_past_meetings_for_user(user_email)
  end

  @doc """
  Sends a reschedule request email for a meeting.

  Validates the request against policy and manages the workflow state.
  """
  @spec send_reschedule_request(MeetingSchema.t()) :: :ok | {:error, String.t() | atom()}
  def send_reschedule_request(meeting) do
    case RescheduleRequest.send_reschedule_request(meeting) do
      :ok ->
        Logger.info("Reschedule request processed", meeting_id: meeting.id)
        :ok

      {:error, :already_requested} ->
        Logger.info("Reschedule already requested", meeting_id: meeting.id)
        :ok

      {:error, reason} = error ->
        Logger.warning("Reschedule request failed", meeting_id: meeting.id, reason: reason)
        error
    end
  end

  @doc """
  Lists all cancelled meetings for a specific user.
  """
  @spec list_cancelled_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_cancelled_meetings_for_user(user_email) do
    Queries.list_cancelled_meetings_for_user(user_email)
  end

  @doc """
  Returns meetings that need reminder emails sent.
  """
  @spec meetings_needing_reminders() :: [MeetingSchema.t()]
  def meetings_needing_reminders do
    Queries.meetings_needing_reminders()
  end

  @doc """
  Cursor-based pagination for a user's meetings.
  """
  @spec list_user_meetings_cursor_page(String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page(user_email, opts \\ []) do
    Queries.list_user_meetings_cursor_page(user_email, opts)
  end

  @doc """
  Cursor-based pagination by user_id.
  """
  @spec list_user_meetings_cursor_page_by_id(integer(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page_by_id(user_id, opts \\ []) do
    Queries.list_user_meetings_cursor_page_by_id(user_id, opts)
  end

  @doc """
  High-level function to list meetings for a user based on a filter string.
  """
  @spec list_user_meetings_by_filter(integer(), String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_by_filter(user_id, filter, opts \\ []) do
    case Queries.list_user_meetings_by_filter(user_id, filter, opts) do
      {:ok, page} ->
        {:ok, page}

      {:error, :invalid_cursor} ->
        Logger.warning("Invalid pagination cursor provided", user_id: user_id)
        {:error, :invalid_cursor}
    end
  rescue
    error ->
      Logger.error("Exception while listing meetings by filter",
        user_id: user_id,
        error: inspect(error),
        stacktrace: __STACKTRACE__
      )

      {:error, :failed_to_list_meetings}
  end

  @doc """
  Gets a single meeting by ID.
  """
  @spec get_meeting(String.t() | integer()) :: {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting(id) do
    Queries.get_meeting(id)
  end

  @doc """
  Gets a single meeting by ID for a specific user.
  """
  @spec get_meeting_for_user(String.t() | integer(), String.t()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting_for_user(id, user_email) do
    case Queries.get_meeting_for_user(id, user_email) do
      {:ok, meeting} -> {:ok, meeting}
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Updates a meeting for a specific user.
  Only the organizer can update a meeting.
  Returns {:ok, meeting} if authorized and updated, {:error, :unauthorized} if not authorized.
  """
  @spec update_meeting_for_user(MeetingSchema.t(), map(), String.t()) ::
          {:ok, MeetingSchema.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def update_meeting_for_user(%MeetingSchema{} = meeting, attrs, user_email)
      when is_binary(user_email) do
    if meeting.organizer_email == user_email do
      MeetingQueries.update_meeting(meeting, attrs)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a meeting for a specific user.
  Only the organizer can delete a meeting.
  Returns {:ok, meeting} if authorized and deleted, {:error, :unauthorized} if not authorized.
  """
  @spec delete_meeting_for_user(MeetingSchema.t(), String.t()) ::
          {:ok, MeetingSchema.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def delete_meeting_for_user(%MeetingSchema{} = meeting, user_email)
      when is_binary(user_email) do
    if meeting.organizer_email == user_email do
      MeetingQueries.delete_meeting(meeting)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Gets a single meeting by ID.
  Raises if not found.
  """
  @spec get_meeting!(String.t()) :: MeetingSchema.t()
  def get_meeting!(id) do
    Queries.get_meeting!(id)
  end
end
