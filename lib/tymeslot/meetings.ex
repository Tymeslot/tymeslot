defmodule Tymeslot.Meetings do
  @moduledoc """
  Business logic for managing meetings and appointments.
  Handles the complete meeting creation workflow including database persistence,
  calendar integration, and email notifications.
  """

  require Logger

  alias Tymeslot.Bookings.{Cancel, Create, Errors, Reschedule, RescheduleRequest}

  alias Tymeslot.Meetings.{
    CalendarEvents,
    ExternalCalendarChanges,
    Guests,
    Listing,
    MeetingCalendarQueries,
    MeetingListQueries,
    MeetingQueries,
    MeetingSchema,
    VideoRooms
  }

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
    - {:error, :slot_taken} if slot is no longer available
    - {:error, reason} on other failures
  """
  @spec create_appointment_with_validation(Create.meeting_params(), map()) ::
          {:ok, Ecto.Schema.t()} | {:error, Errors.classified_error() | String.t()}
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

  @doc """
  Creates a calendar event asynchronously (does not fail the booking workflow if scheduling fails).
  """
  defdelegate create_calendar_event_async(meeting), to: CalendarEvents

  @doc "Looks up a guest by their RSVP token without mutating anything."
  defdelegate get_guest_by_token(token), to: Guests, as: :get_by_token

  @doc """
  Records a guest's RSVP (`"accepted"` / `"declined"`) from their token.
  """
  defdelegate record_guest_rsvp(token, response), to: Guests, as: :record_rsvp

  @doc "Lists the guests attached to a meeting, oldest first."
  defdelegate list_meeting_guests(meeting_id), to: Guests, as: :list_for_meeting

  @doc "Aggregates RSVP counts for a list of guests."
  defdelegate guest_rsvp_summary(guests), to: Guests, as: :summarize

  @doc "Returns a `meeting_uid => RSVP summary` map for a user's guest meetings."
  defdelegate guest_rsvp_summaries_for_user(user_id),
    to: Tymeslot.Meetings.GuestQueries,
    as: :rsvp_summaries_for_user

  @doc """
  Schedules email notifications for a meeting via Oban.
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

  The `organizer_user_id` is required. The meeting lookup is scoped to that
  owner, preventing IDOR attacks from the public booking flow.
  """
  @spec reschedule_meeting(String.t(), Reschedule.reschedule_params(), map(), integer()) ::
          {:ok, Ecto.Schema.t()} | {:error, term()}
  def reschedule_meeting(meeting_uid, new_params, form_data, organizer_user_id) do
    Reschedule.execute(meeting_uid, new_params, form_data, organizer_user_id)
  end

  @doc """
  Cancels the calendar event associated with a meeting asynchronously.

  Schedules calendar event deletion through an Oban worker. Does not fail the
  broader cancellation workflow if scheduling fails.
  """
  defdelegate cancel_calendar_event(meeting), to: CalendarEvents

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
    MeetingListQueries.list_upcoming_meetings()
  end

  @doc """
  Lists upcoming meetings for a specific user with a limit.
  """
  @spec list_upcoming_meetings_for_user(String.t(), integer()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email, limit) do
    MeetingListQueries.upcoming_meetings_for_user(user_email, limit)
  end

  @doc """
  Lists all upcoming meetings for a specific user.
  """
  @spec list_upcoming_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email) do
    MeetingListQueries.list_upcoming_meetings_for_user(user_email)
  end

  @doc """
  Lists all past meetings.
  """
  @spec list_past_meetings() :: [MeetingSchema.t()]
  def list_past_meetings do
    MeetingListQueries.list_past_meetings()
  end

  @doc """
  Lists past meetings for a specific user.
  """
  @spec list_past_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_past_meetings_for_user(user_email) do
    MeetingListQueries.list_past_meetings_for_user(user_email)
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
    MeetingListQueries.list_cancelled_meetings_for_user(user_email)
  end

  @doc """
  Returns meetings that need reminder emails sent.

  Finds confirmed meetings starting within the next hour that still have
  unsent reminders.
  """
  @spec meetings_needing_reminders() :: [MeetingSchema.t()]
  defdelegate meetings_needing_reminders(), to: Listing

  @doc """
  Cursor-based pagination for a user's meetings.
  """
  @spec list_user_meetings_cursor_page(String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page(user_email, opts \\ []) do
    Listing.list_user_meetings_cursor_page(user_email, opts)
  end

  @doc """
  Cursor-based pagination by user_id.
  """
  @spec list_user_meetings_cursor_page_by_id(integer(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_cursor_page_by_id(user_id, opts \\ []) do
    Listing.list_user_meetings_cursor_page_by_id(user_id, opts)
  end

  @doc """
  High-level function to list meetings for a user based on a filter string.
  """
  @spec list_user_meetings_by_filter(integer(), String.t(), keyword()) ::
          {:ok, CursorPage.t()} | {:error, :invalid_cursor}
  def list_user_meetings_by_filter(user_id, filter, opts \\ []) do
    Listing.list_user_meetings_by_filter(user_id, filter, opts)
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
  Gets a single meeting by its unique identifier (UID).
  """
  @spec get_meeting_by_uid(String.t()) :: {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting_by_uid(uid) do
    MeetingQueries.get_meeting_by_uid(uid)
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
  Fetches a meeting by UID only if the given `organizer_user_id` owns it.

  Returns `{:ok, meeting}` when a matching meeting is found.
  Returns `{:error, :not_found}` when no meeting exists with that UID, or when
  the meeting exists but belongs to a different organizer.

  Use this instead of `get_meeting_by_uid/1` on any user-facing route that
  accepts a meeting UID from the URL, to prevent IDOR attacks.
  """
  @spec get_meeting_by_uid_for_organizer(String.t(), integer()) ::
          {:ok, MeetingSchema.t()} | {:error, :not_found}
  def get_meeting_by_uid_for_organizer(uid, organizer_user_id) do
    MeetingQueries.get_meeting_by_uid_for_organizer(uid, organizer_user_id)
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

  @doc """
  Applies an externally detected calendar change (`:deleted` or `:modified`)
  to the meeting linked to the given provider event, if any.

  This is the entry point the Calendar context uses when a sync worker
  detects that a provider event linked to a meeting changed externally.
  Owns all meeting-side consequences: sync-status updates, auto-cancellation
  on external deletion, and host notifications.
  """
  defdelegate apply_external_calendar_change(
                calendar_integration_id,
                provider_event_id,
                uid,
                signal
              ),
              to: ExternalCalendarChanges,
              as: :apply_change

  @doc """
  Looks up a meeting linked to a calendar event by provider event ID or UID.

  Returns `{:ok, meeting}` or `{:error, :not_found}`. Tries
  `provider_event_id` first, falls back to `uid`.
  """
  defdelegate find_meeting_by_calendar_event(calendar_integration_id, provider_event_id, uid),
    to: ExternalCalendarChanges,
    as: :find_linked_meeting

  @doc """
  Returns a map from `provider_event_id` to meeting for all meetings linked
  to the given integration whose `provider_event_id` is in the supplied list.
  """
  defdelegate list_meetings_by_provider_event_ids(calendar_integration_id, provider_event_ids),
    to: MeetingCalendarQueries,
    as: :list_by_provider_event_ids

  # =====================================
  # Analytics Query Functions
  # =====================================

  @doc "Counts all bookings (any status) for an organizer in the window; analytics volume primitive."
  @spec count_bookings(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_bookings(organizer_user_id, from, to), to: MeetingQueries

  @doc "Booking counts grouped by `utm_source` (set rows only); primitive for `Analytics.attribution_table/3`."
  @spec bookings_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), bookings: non_neg_integer()}
        ]
  defdelegate bookings_by_utm_source(organizer_user_id, from, to),
    to: MeetingQueries,
    as: :count_by_utm_source

  @doc "Counts distinct converting visitors (bookings carrying a `visitor_hash`) in the window."
  @spec count_converting_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  defdelegate count_converting_visitors(organizer_user_id, from, to), to: MeetingQueries

  @doc "Distinct converting-visitor counts grouped by `utm_source`; primitive for `Analytics.attribution_table/3`."
  @spec converting_visitors_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), converting_visitors: non_neg_integer()}
        ]
  defdelegate converting_visitors_by_utm_source(organizer_user_id, from, to), to: MeetingQueries
end
