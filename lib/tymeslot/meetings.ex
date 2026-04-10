defmodule Tymeslot.Meetings do
  @moduledoc """
  Business logic for managing meetings and appointments.
  Handles the complete meeting creation workflow including database persistence,
  calendar integration, and email notifications.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Bookings.{Cancel, Create, Reschedule, RescheduleRequest}
  alias Tymeslot.Integrations.Calendar.CalendarEventScheduler
  alias Tymeslot.Meetings.{MeetingCalendarQueries, MeetingQueries, MeetingSchema, VideoRooms}
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Pagination.CursorPage
  alias Tymeslot.Utils.DateTimeUtils

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
  @spec create_appointment_with_validation(Create.meeting_params(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, String.t()}
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
  @spec create_appointment(Create.meeting_params(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, String.t()}
  def create_appointment(meeting_params, validated_form_data) do
    Create.execute(meeting_params, validated_form_data, skip_calendar_check: true)
  end

  @doc """
  Creates a DateTime safely with timezone fallback.
  """
  @spec create_datetime_safe(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def create_datetime_safe(date, time, timezone) do
    DateTimeUtils.create_datetime_safe(date, time, timezone)
  end

  # Private functions

  @doc """
  Create calendar event asynchronously (don't fail the whole process if this fails).
  """
  @spec create_calendar_event_async(Ecto.Schema.t()) :: :ok
  def create_calendar_event_async(meeting) do
    # Schedule calendar event creation through Oban worker
    case CalendarEventScheduler.schedule_calendar_creation(meeting.id) do
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
  @spec reschedule_meeting(String.t(), Reschedule.reschedule_params(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  def reschedule_meeting(meeting_uid, new_params, form_data) do
    Reschedule.execute(meeting_uid, new_params, form_data)
  end

  @doc false
  @spec cancel_calendar_event(Ecto.Schema.t()) :: :ok
  def cancel_calendar_event(meeting) do
    Logger.info("Scheduling calendar event cancellation",
      meeting_id: meeting.id,
      uid: meeting.uid
    )

    # Schedule calendar event deletion through Oban worker
    case CalendarEventScheduler.schedule_calendar_deletion(meeting.id) do
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
      Logger.warning("Exception while scheduling calendar event cancellation",
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
  @spec create_appointment_with_video_room(Create.meeting_params(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, String.t()}
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
    MeetingQueries.list_upcoming_meetings()
  end

  @doc """
  Lists upcoming meetings for a specific user with a limit.
  """
  @spec list_upcoming_meetings_for_user(String.t(), integer()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email, limit) do
    MeetingQueries.upcoming_meetings_for_user(user_email, limit)
  end

  @doc """
  Lists all upcoming meetings for a specific user.
  """
  @spec list_upcoming_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email) do
    MeetingQueries.list_upcoming_meetings_for_user(user_email)
  end

  @doc """
  Lists all past meetings.
  """
  @spec list_past_meetings() :: [MeetingSchema.t()]
  def list_past_meetings do
    MeetingQueries.list_past_meetings()
  end

  @doc """
  Lists past meetings for a specific user.
  """
  @spec list_past_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_past_meetings_for_user(user_email) do
    MeetingQueries.list_past_meetings_for_user(user_email)
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
    MeetingQueries.list_cancelled_meetings_for_user(user_email)
  end

  @doc """
  Returns meetings that need reminder emails sent.

  Finds confirmed meetings starting within the next hour that still have
  unsent reminders.
  """
  @spec meetings_needing_reminders() :: [MeetingSchema.t()]
  def meetings_needing_reminders do
    now = DateTime.utc_now()
    one_hour_from_now = DateTime.add(now, 1, :hour)

    Enum.filter(
      MeetingQueries.list_meetings_needing_reminders(now, one_hour_from_now),
      &needs_reminder?/1
    )
  end

  @doc """
  Cursor-based pagination for a user's meetings.
  """
  @spec list_user_meetings_cursor_page(String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page(user_email, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    cursor = Keyword.get(opts, :after)

    case decode_cursor_opt(cursor) do
      :no_cursor ->
        items = list_user_meetings_internal(user_email, opts)
        {:ok, build_cursor_page(items, per_page)}

      {:ok, %{after_start: after_start, after_id: after_id}} ->
        items =
          opts
          |> Keyword.put(:after_start, after_start)
          |> Keyword.put(:after_id, after_id)
          |> then(&list_user_meetings_internal(user_email, &1))

        {:ok, build_cursor_page(items, per_page)}

      {:error, :invalid_cursor} ->
        {:error, :invalid_cursor}
    end
  end

  @doc """
  Cursor-based pagination by user_id.
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

  @doc """
  High-level function to list meetings for a user based on a filter string.
  """
  @spec list_user_meetings_by_filter(integer(), String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_by_filter(user_id, filter, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    after_cursor = Keyword.get(opts, :after)

    query_opts =
      case filter do
        "upcoming" -> [time_filter: :upcoming, exclude_status: "cancelled"]
        "past" -> [time_filter: :past, exclude_status: "cancelled"]
        "cancelled" -> [status: "cancelled"]
        _other -> []
      end

    query_opts = Keyword.merge(query_opts, per_page: per_page)

    query_opts =
      if after_cursor, do: Keyword.put(query_opts, :after, after_cursor), else: query_opts

    case list_user_meetings_cursor_page_by_id(user_id, query_opts) do
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
    case MeetingQueries.get_meeting(id) do
      {:ok, meeting} -> {:ok, meeting}
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Gets a single meeting by ID for a specific user.

  Verifies that the meeting belongs to the specified user
  (either as organizer or attendee) before returning it.
  """
  @spec get_meeting_for_user(String.t() | integer(), String.t()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting_for_user(id, user_email) do
    with {:ok, meeting} <- MeetingQueries.get_meeting(id),
         true <- meeting.organizer_email == user_email or meeting.attendee_email == user_email do
      {:ok, meeting}
    else
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Gets a single meeting by UID for a specific user.

  Verifies that the meeting belongs to the specified user
  (either as organizer or attendee) before returning it.
  """
  @spec get_meeting_by_uid_for_user(String.t(), String.t()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting_by_uid_for_user(uid, user_email) do
    with {:ok, meeting} <- MeetingQueries.get_meeting_by_uid(uid),
         true <- meeting.organizer_email == user_email or meeting.attendee_email == user_email do
      {:ok, meeting}
    else
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
    case MeetingQueries.get_meeting(id) do
      {:ok, meeting} ->
        meeting

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: MeetingSchema
    end
  end

  @doc """
  Dismisses the calendar sync status banner for a meeting by recording the current timestamp.

  Returns `{:ok, meeting}` on success or `{:error, :not_found}` if the meeting does not exist.
  """
  @spec dismiss_calendar_sync_status(String.t(), integer()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def dismiss_calendar_sync_status(meeting_id, user_id) do
    MeetingCalendarQueries.dismiss_calendar_sync_status(meeting_id, user_id)
  end

  # =====================================
  # Private Helper Functions
  # =====================================

  defp list_user_meetings_internal(user_email, opts) do
    per_page = Keyword.get(opts, :per_page, 20)
    status = Keyword.get(opts, :status)
    exclude_status = Keyword.get(opts, :exclude_status)
    time_filter = Keyword.get(opts, :time_filter)
    after_start = Keyword.get(opts, :after_start)
    after_id = Keyword.get(opts, :after_id)

    MeetingQueries.list_meetings_for_user_paginated_cursor(user_email,
      per_page: per_page,
      status: status,
      exclude_status: exclude_status,
      time_filter: time_filter,
      after_start: after_start,
      after_id: after_id
    )
  end

  defp decode_cursor_opt(nil), do: :no_cursor
  defp decode_cursor_opt(""), do: :no_cursor

  defp decode_cursor_opt(cursor) when is_binary(cursor) do
    CursorPage.decode_cursor(cursor)
  end

  defp build_cursor_page(items, per_page) do
    {items, has_more} =
      if length(items) > per_page do
        {Enum.drop(items, -1), true}
      else
        {items, false}
      end

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

  defp needs_reminder?(meeting) do
    case meeting.reminders do
      nil ->
        not meeting.reminder_email_sent

      [] ->
        false

      reminders when is_list(reminders) ->
        reminders_sent = meeting.reminders_sent || []
        length(reminders) > length(reminders_sent)

      _other ->
        true
    end
  end
end
