defmodule Tymeslot.Meetings.Queries do
  @moduledoc """
  Query orchestration for meetings.

  This module provides high-level query operations for meetings, following CQRS
  principles by separating read operations from write operations. It adds business
  logic on top of the low-level DatabaseQueries.MeetingQueries module.

  Responsibilities:
  - Meeting listings with time-based filtering (upcoming, past, cancelled)
  - Single meeting retrieval with authorization checks
  - Cursor-based pagination for efficient large dataset handling
  - Business logic for reminder email scheduling
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.DatabaseQueries.MeetingQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema
  alias Tymeslot.Pagination.CursorPage

  # =====================================
  # Basic Query Functions
  # =====================================

  @doc """
  Lists all upcoming meetings across all users.

  ## Returns
    - List of meetings with start_time >= current time
  """
  @spec list_upcoming_meetings() :: [MeetingSchema.t()]
  def list_upcoming_meetings do
    MeetingQueries.list_upcoming_meetings()
  end

  @doc """
  Lists upcoming meetings for a specific user with a limit.

  ## Parameters
    - user_email: Email address of the user
    - limit: Maximum number of meetings to return

  ## Returns
    - List of meetings for the user with start_time >= current time
  """
  @spec list_upcoming_meetings_for_user(String.t(), integer()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email, limit) do
    MeetingQueries.upcoming_meetings_for_user(user_email, limit)
  end

  @doc """
  Lists all upcoming meetings for a specific user.

  ## Parameters
    - user_email: Email address of the user

  ## Returns
    - List of all upcoming meetings for the user
  """
  @spec list_upcoming_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_upcoming_meetings_for_user(user_email) do
    MeetingQueries.list_upcoming_meetings_for_user(user_email)
  end

  @doc """
  Lists all past meetings across all users.

  ## Returns
    - List of meetings with end_time < current time
  """
  @spec list_past_meetings() :: [MeetingSchema.t()]
  def list_past_meetings do
    MeetingQueries.list_past_meetings()
  end

  @doc """
  Lists past meetings for a specific user.

  ## Parameters
    - user_email: Email address of the user

  ## Returns
    - List of past meetings for the user
  """
  @spec list_past_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_past_meetings_for_user(user_email) do
    MeetingQueries.list_past_meetings_for_user(user_email)
  end

  @doc """
  Lists all cancelled meetings for a specific user.

  ## Parameters
    - user_email: Email address of the user

  ## Returns
    - List of cancelled meetings for the user
  """
  @spec list_cancelled_meetings_for_user(String.t()) :: [MeetingSchema.t()]
  def list_cancelled_meetings_for_user(user_email) do
    MeetingQueries.list_cancelled_meetings_for_user(user_email)
  end

  @doc """
  Returns meetings that need reminder emails sent.

  Business logic: Finds meetings that are:
  - Starting within the next hour
  - Have reminder_email_sent = false
  - Are in confirmed status

  ## Returns
    - List of meetings needing reminders

  ## Examples

      iex> meetings_needing_reminders()
      [%Meeting{}, ...]
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

  # =====================================
  # Single Meeting Queries
  # =====================================

  @doc """
  Gets a single meeting by ID.

  ## Parameters
    - id: Meeting ID (string or integer)

  ## Returns
    - {:ok, meeting} if found
    - {:error, :not_found} if not found
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

  This function verifies that the meeting belongs to the specified user
  (either as organizer or attendee) before returning it.

  ## Parameters
    - id: Meeting ID (string or integer)
    - user_email: Email address of the user

  ## Returns
    - {:ok, meeting} if found and belongs to user
    - {:error, :not_found} if not found or doesn't belong to user
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

  This function verifies that the meeting belongs to the specified user
  (either as organizer or attendee) before returning it.

  ## Parameters
    - uid: Meeting UID (string)
    - user_email: Email address of the user

  ## Returns
    - {:ok, meeting} if found and belongs to user
    - {:error, :not_found} if not found or doesn't belong to user
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
  Gets a single meeting by ID.

  Raises `Ecto.NoResultsError` if not found.

  ## Parameters
    - id: Meeting ID (string)

  ## Returns
    - The meeting if found

  ## Raises
    - Ecto.NoResultsError if meeting not found
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

  # =====================================
  # Cursor Pagination Functions
  # =====================================

  @doc """
  Cursor-based pagination for a user's meetings.

  This provides efficient pagination for large datasets by using cursor-based
  navigation rather than offset-based pagination.

  ## Options
    - :per_page (default 20) - Number of items per page
    - :status (e.g., "confirmed") - Filter by meeting status
    - :exclude_status (e.g., "cancelled") - Exclude specific status
    - :time_filter (:upcoming | :past | nil) - Filter by time
    - :after (cursor string) - Cursor for next page

  ## Returns
    - {:ok, %CursorPage{}} with items and pagination metadata
    - {:error, :invalid_cursor} if cursor is malformed

  ## Examples

      iex> list_user_meetings_cursor_page("user@example.com", per_page: 10)
      {:ok, %CursorPage{items: [...], next_cursor: "...", has_more: true}}

      iex> list_user_meetings_cursor_page("user@example.com", time_filter: :upcoming)
      {:ok, %CursorPage{items: [...], has_more: false}}
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

  Resolves the user_id to email internally to avoid coupling callers to email.

  ## Parameters
    - user_id: User ID (integer)
    - opts: Same options as list_user_meetings_cursor_page/2

  ## Returns
    - {:ok, %CursorPage{}} with items and pagination metadata
    - {:error, :invalid_cursor} if cursor is malformed
    - Returns empty page if user not found

  ## Examples

      iex> list_user_meetings_cursor_page_by_id(123, per_page: 5)
      {:ok, %CursorPage{items: [...], has_more: true}}
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

  This is commonly used in dashboard views to show different meeting categories.

  ## Parameters
    - user_id: User ID (integer)
    - filter: Filter string ("upcoming" | "past" | "cancelled")
    - opts: Pagination options (per_page, after cursor)

  ## Returns
    - {:ok, %CursorPage{}} with filtered meetings
    - {:error, :invalid_cursor} if cursor is malformed

  ## Examples

      iex> list_user_meetings_by_filter(123, "upcoming", per_page: 10)
      {:ok, %CursorPage{items: [...]}}

      iex> list_user_meetings_by_filter(123, "cancelled")
      {:ok, %CursorPage{items: [...]}}
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

    list_user_meetings_cursor_page_by_id(user_id, query_opts)
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
