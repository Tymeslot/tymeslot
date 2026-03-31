defmodule Tymeslot.DatabaseQueries.MeetingQueries do
  @moduledoc """
  Database queries for Meeting schema.

  This module provides a clean interface for all database operations
  related to meetings. It focuses on pure data access - business logic
  should be handled in the Tymeslot.Meetings context module.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.DatabaseSchemas.MeetingSchema, as: Meeting
  alias Tymeslot.Repo
  alias Tymeslot.Utils.ReminderUtils

  @doc false
  # Private helper: filter meetings where the given email matches organizer OR attendee.
  defp for_user_email(query, email) do
    from(m in query,
      where: m.organizer_email == ^email or m.attendee_email == ^email
    )
  end

  @doc false
  defp for_attendee_email(query, email) do
    from(m in query, where: m.attendee_email == ^email)
  end

  @doc false
  defp for_organizer_email(query, email) do
    from(m in query, where: m.organizer_email == ^email)
  end

  @doc false
  # Private helper: optionally filter by exact status when provided.
  defp with_status(query, nil), do: query
  defp with_status(query, status), do: from(m in query, where: m.status == ^status)

  @doc false
  defp without_status(query, nil), do: query
  defp without_status(query, ""), do: query

  defp without_status(query, status) when is_list(status),
    do: from(m in query, where: m.status not in ^status)

  defp without_status(query, status), do: from(m in query, where: m.status != ^status)

  @doc false
  # Private helper: filter upcoming meetings (not yet ended).
  defp upcoming(query, now), do: from(m in query, where: m.end_time > ^now)

  @doc false
  # Private helper: filter past meetings strictly before the provided timestamp.
  defp past(query, now), do: from(m in query, where: m.end_time < ^now)

  @doc false
  defp order_by_start_desc(query), do: from(m in query, order_by: [desc: m.start_time])

  @doc false
  defp order_by_start_asc(query), do: from(m in query, order_by: [asc: m.start_time])

  @doc false
  defp paginate_offset(query, page, per_page),
    do: from(m in query, limit: ^per_page, offset: ^((page - 1) * per_page))

  @doc false
  defp apply_limit(query, limit), do: from(m in query, limit: ^limit)

  @doc false
  defp apply_time_filter(query, nil, _now), do: query
  defp apply_time_filter(query, :upcoming, now), do: upcoming(query, now)
  defp apply_time_filter(query, :past, now), do: past(query, now)

  @doc false
  defp cursor_after(query, nil, _after_id), do: query
  defp cursor_after(query, _after_start, nil), do: query

  defp cursor_after(query, after_start, after_id) do
    from(m in query,
      where:
        m.start_time < ^after_start or
          (m.start_time == ^after_start and m.id < ^after_id)
    )
  end

  @doc false
  defp order_by_start_desc_id_desc(query),
    do: from(m in query, order_by: [desc: m.start_time, desc: m.id])

  @doc """
  Creates a meeting.

  ## Examples

      iex> create_meeting(%{uid: "unique-123", title: "Meeting"})
      {:ok, %Meeting{}}

      iex> create_meeting(%{bad_field: "bad_value"})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_meeting(map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def create_meeting(attrs \\ %{}) when is_map(attrs) do
    %Meeting{}
    |> Meeting.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a single meeting by ID.

  ## Examples

      iex> get_meeting(meeting_id)
      {:ok, %Meeting{}}

      iex> get_meeting("non-existent-id")
      {:error, :not_found}

  """
  @spec get_meeting(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting(id) do
    case UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Meeting, uuid) do
          nil -> {:error, :not_found}
          meeting -> {:ok, meeting}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets a single meeting by ID and locks it for update.
  """
  @spec get_meeting_for_update(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_for_update(id) do
    case UUID.cast(id) do
      {:ok, uuid} ->
        query = from(m in Meeting, where: m.id == ^uuid, lock: "FOR UPDATE")

        case Repo.one(query) do
          nil -> {:error, :not_found}
          meeting -> {:ok, meeting}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets a single meeting by UID.

  ## Examples

      iex> get_meeting_by_uid("unique-uid")
      {:ok, %Meeting{}}

      iex> get_meeting_by_uid("non-existent-uid")
      {:error, :not_found}

  """
  @spec get_meeting_by_uid(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid(uid) do
    case Repo.get_by(Meeting, uid: uid) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Updates a meeting.

  ## Examples

      iex> update_meeting(meeting, %{title: "New Title"})
      {:ok, %Meeting{}}

      iex> update_meeting(meeting, %{title: nil})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_meeting(Meeting.t(), map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def update_meeting(%Meeting{} = meeting, attrs) when is_map(attrs) do
    meeting
    |> Meeting.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a meeting.

  ## Examples

      iex> delete_meeting(meeting)
      {:ok, %Meeting{}}

      iex> delete_meeting(%Meeting{id: "non-existent"})
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_meeting(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def delete_meeting(%Meeting{} = meeting) do
    Repo.delete(meeting)
  end

  @doc """
  Returns the list of all meetings.

  ## Examples

      iex> list_meetings()
      [%Meeting{}, ...]

  """
  @spec list_meetings() :: [Meeting.t()]
  def list_meetings do
    Meeting
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Returns the list of meetings with a specific status.

  ## Examples

      iex> list_meetings_by_status("confirmed")
      [%Meeting{}, ...]

  """
  @spec list_meetings_by_status(String.t()) :: [Meeting.t()]
  def list_meetings_by_status(status) do
    Meeting
    |> with_status(status)
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Returns the list of meetings within a date range.

  ## Examples

      iex> list_meetings_by_date_range(~U[2024-01-01 00:00:00Z], ~U[2024-01-02 00:00:00Z])
      [%Meeting{}, ...]

  """
  @spec list_meetings_by_date_range(DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def list_meetings_by_date_range(%DateTime{} = start_date, %DateTime{} = end_date) do
    query =
      from(m in Meeting,
        where: m.start_time >= ^start_date and m.start_time <= ^end_date,
        order_by: [asc: m.start_time]
      )

    Repo.all(query)
  end

  @doc """
  Returns the list of upcoming meetings (future meetings only).

  ## Examples

      iex> list_upcoming_meetings()
      [%Meeting{}, ...]

  """
  @spec list_upcoming_meetings() :: [Meeting.t()]
  def list_upcoming_meetings do
    now = DateTime.utc_now()

    Meeting
    |> upcoming(now)
    |> order_by_start_asc()
    |> Repo.all()
  end

  @doc """
  Returns the list of meetings for a specific attendee email.

  ## Examples

      iex> list_meetings_by_attendee_email("attendee@example.com")
      [%Meeting{}, ...]

  """
  @spec list_meetings_by_attendee_email(String.t()) :: [Meeting.t()]
  def list_meetings_by_attendee_email(email) do
    Meeting
    |> for_attendee_email(email)
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Returns the list of meetings for a specific organizer email.

  ## Examples

      iex> list_meetings_by_organizer_email("organizer@example.com")
      [%Meeting{}, ...]

  """
  @spec list_meetings_by_organizer_email(String.t()) :: [Meeting.t()]
  def list_meetings_by_organizer_email(email) do
    Meeting
    |> for_organizer_email(email)
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Marks an email as sent for a meeting.

  ## Examples

      iex> mark_email_sent(meeting, :organizer)
      {:ok, %Meeting{}}

      iex> mark_email_sent(meeting, :attendee)
      {:ok, %Meeting{}}

      iex> mark_email_sent(meeting, :reminder)
      {:ok, %Meeting{}}

      iex> mark_email_sent(meeting, :invalid)
      {:error, :invalid_email_type}

  """
  @spec mark_email_sent(Meeting.t(), :organizer | :attendee | :reminder | atom()) ::
          {:ok, Meeting.t()} | {:error, :invalid_email_type | Changeset.t()}
  def mark_email_sent(%Meeting{} = meeting, email_type) do
    attrs =
      case email_type do
        :organizer -> %{organizer_email_sent: true}
        :attendee -> %{attendee_email_sent: true}
        :reminder -> %{reminder_email_sent: true}
        _other -> nil
      end

    if attrs do
      update_meeting(meeting, attrs)
    else
      {:error, :invalid_email_type}
    end
  end

  @doc """
  Appends a reminder to reminders_sent and marks reminders as sent.
  """
  @spec append_reminder_sent(Meeting.t(), integer(), String.t()) ::
          {:ok, Meeting.t()} | {:error, Changeset.t() | :invalid_reminder | :not_found}
  def append_reminder_sent(%Meeting{} = meeting, reminder_value, reminder_unit) do
    case ReminderUtils.normalize_reminder(%{value: reminder_value, unit: reminder_unit}) do
      {:ok, %{value: val, unit: unit}} ->
        new_reminder = %{"value" => val, "unit" => unit}
        new_reminder_list = [new_reminder]

        {count, _value} =
          Repo.update_all(
            from(m in Meeting,
              where: m.id == ^meeting.id,
              update: [
                set: [
                  reminder_email_sent: true,
                  reminders_sent:
                    fragment(
                      "CASE WHEN COALESCE(reminders_sent, ARRAY[]::jsonb[]) @> ?::jsonb[] THEN COALESCE(reminders_sent, ARRAY[]::jsonb[]) ELSE array_append(COALESCE(reminders_sent, ARRAY[]::jsonb[]), ?::jsonb) END",
                      ^new_reminder_list,
                      ^new_reminder
                    )
                ]
              ]
            ),
            []
          )

        if count == 1 do
          get_meeting(meeting.id)
        else
          {:error, :not_found}
        end

      _other ->
        {:error, :invalid_reminder}
    end
  end

  @doc """
  Returns the count of meetings with a specific status.

  ## Examples

      iex> count_meetings_by_status("confirmed")
      5

  """
  @spec count_meetings_by_status(String.t()) :: non_neg_integer()
  def count_meetings_by_status(status) do
    Repo.aggregate(from(m in Meeting, where: m.status == ^status), :count, :id)
  end

  @doc """
  Returns the count of meetings for a specific attendee.

  ## Examples

      iex> count_meetings_by_attendee_email("attendee@example.com")
      3

  """
  @spec count_meetings_by_attendee_email(String.t()) :: non_neg_integer()
  def count_meetings_by_attendee_email(email) do
    Repo.aggregate(from(m in Meeting, where: m.attendee_email == ^email), :count, :id)
  end

  @doc """
  Returns the count of meetings for a specific organizer.

  ## Examples

      iex> count_meetings_by_organizer_email("organizer@example.com")
      10

  """
  @spec count_meetings_by_organizer_email(String.t()) :: non_neg_integer()
  def count_meetings_by_organizer_email(email) do
    Repo.aggregate(from(m in Meeting, where: m.organizer_email == ^email), :count, :id)
  end

  @doc """
  Returns meetings in the reminder window with confirmed status.
  Business logic for determining which meetings need reminders should be in the Meetings context.
  """
  @spec list_meetings_needing_reminders(DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def list_meetings_needing_reminders(start_time, end_time) do
    base_query =
      from(m in Meeting,
        where:
          m.start_time >= ^start_time and
            m.start_time <= ^end_time and
            m.status == "confirmed",
        order_by: [asc: m.start_time]
      )

    Repo.all(base_query)
  end

  @doc """
  Finds a meeting by its external provider event ID and calendar integration.

  Returns `{:ok, meeting}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_by_provider_event_id(integer(), String.t()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_by_provider_event_id(calendar_integration_id, provider_event_id) do
    result =
      Meeting
      |> where(
        [m],
        m.calendar_integration_id == ^calendar_integration_id and
          m.provider_event_id == ^provider_event_id
      )
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Finds a meeting by its UID and calendar integration.

  Returns `{:ok, meeting}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_by_uid_and_integration(integer(), String.t()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_by_uid_and_integration(calendar_integration_id, uid) do
    result =
      Meeting
      |> where(
        [m],
        m.calendar_integration_id == ^calendar_integration_id and m.uid == ^uid
      )
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Updates `calendar_sync_status` on a meeting and clears `calendar_sync_status_dismissed_at`.

  `status` should be one of `"externally_deleted"` or `"externally_modified"`.

  Returns `{:ok, meeting}` on success or `{:error, :not_found}` if no row matched.
  """
  @valid_sync_statuses ~w(externally_deleted externally_modified)

  @spec clear_calendar_sync_status(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def clear_calendar_sync_status(meeting_id) do
    {count, _rows} =
      Meeting
      |> where([m], m.id == ^meeting_id)
      |> Repo.update_all(
        set: [
          calendar_sync_status: nil,
          calendar_sync_status_dismissed_at: nil,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    if count > 0 do
      get_meeting(meeting_id)
    else
      {:error, :not_found}
    end
  end

  @spec update_calendar_sync_status(String.t(), String.t()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def update_calendar_sync_status(meeting_id, status) when status in @valid_sync_statuses do
    {count, _rows} =
      Meeting
      |> where([m], m.id == ^meeting_id)
      |> Repo.update_all(
        set: [
          calendar_sync_status: status,
          calendar_sync_status_dismissed_at: nil,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    if count > 0 do
      get_meeting(meeting_id)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Atomically updates `calendar_sync_status` only when the current value differs.

  Returns `{:ok, meeting}` if the row was updated, `{:ok, :already_set}` if the
  status already matched (no email should be sent), or `{:error, :not_found}`.
  """
  @spec update_calendar_sync_status_if_changed(String.t(), String.t()) ::
          {:ok, Meeting.t()} | {:ok, :already_set} | {:error, :not_found}
  def update_calendar_sync_status_if_changed(meeting_id, status)
      when status in @valid_sync_statuses do
    # Only update rows where status differs (or is nil when we want to set it)
    {count, _rows} =
      Meeting
      |> where([m], m.id == ^meeting_id)
      |> where([m], m.calendar_sync_status != ^status or is_nil(m.calendar_sync_status))
      |> Repo.update_all(
        set: [
          calendar_sync_status: status,
          calendar_sync_status_dismissed_at: nil,
          updated_at: DateTime.utc_now(:second)
        ]
      )

    cond do
      count > 0 -> get_meeting(meeting_id)
      Repo.exists?(where(Meeting, [m], m.id == ^meeting_id)) -> {:ok, :already_set}
      true -> {:error, :not_found}
    end
  end

  @doc """
  Sets `calendar_sync_status_dismissed_at` to the current UTC time for a meeting.

  Returns `{:ok, meeting}` on success or `{:error, :not_found}` if no row matched.
  """
  @spec dismiss_calendar_sync_status(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def dismiss_calendar_sync_status(meeting_id, user_id) do
    now = DateTime.utc_now(:second)

    {count, _rows} =
      Meeting
      |> where([m], m.id == ^meeting_id and m.organizer_user_id == ^user_id)
      |> Repo.update_all(
        set: [
          calendar_sync_status_dismissed_at: now,
          updated_at: now
        ]
      )

    if count > 0 do
      get_meeting(meeting_id)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Returns upcoming meetings that should have a video room link but do not.
  """
  @spec list_meetings_missing_video_rooms(DateTime.t(), pos_integer()) :: [Meeting.t()]
  def list_meetings_missing_video_rooms(now, limit \\ 500) do
    Meeting
    |> with_status("confirmed")
    |> upcoming(now)
    |> where([m], not is_nil(m.video_integration_id))
    |> where([m], is_nil(m.video_room_id))
    |> order_by([m], asc: m.start_time)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Get upcoming meetings with preloaded associations.
  Limits results and orders by start time.
  """
  @spec upcoming_meetings(non_neg_integer()) :: [Meeting.t()]
  def upcoming_meetings(limit \\ 3) do
    now = DateTime.utc_now()

    Meeting
    |> with_status("confirmed")
    |> upcoming(now)
    |> order_by_start_asc()
    |> apply_limit(limit)
    |> Repo.all()
  end

  @doc """
  Get upcoming meetings for a specific user with limit.
  Filters by user email as either organizer or attendee.
  """
  @spec upcoming_meetings_for_user(String.t(), non_neg_integer()) :: [Meeting.t()]
  def upcoming_meetings_for_user(user_email, limit \\ 3) do
    now = DateTime.utc_now()

    Meeting
    |> with_status("confirmed")
    |> upcoming(now)
    |> for_user_email(user_email)
    |> order_by_start_asc()
    |> apply_limit(limit)
    |> Repo.all()
  end

  @doc """
  Get upcoming meetings for a specific user with proper database filtering.
  Replaces the N+1 pattern of loading all meetings and filtering in memory.
  """
  @spec list_upcoming_meetings_for_user(String.t()) :: [Meeting.t()]
  def list_upcoming_meetings_for_user(user_email) do
    now = DateTime.utc_now()

    Meeting
    |> for_user_email(user_email)
    |> upcoming(now)
    |> order_by_start_asc()
    |> Repo.all()
  end

  @doc """
  Get all past meetings across all users.
  """
  @spec list_past_meetings() :: [Meeting.t()]
  def list_past_meetings do
    now = DateTime.utc_now()

    Meeting
    |> past(now)
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Get past meetings for a specific user with proper database filtering.
  Replaces the N+1 pattern of loading all meetings and filtering in memory.
  """
  @spec list_past_meetings_for_user(String.t()) :: [Meeting.t()]
  def list_past_meetings_for_user(user_email) do
    now = DateTime.utc_now()

    Meeting
    |> for_user_email(user_email)
    |> past(now)
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Get cancelled meetings for a specific user with proper database filtering.
  Replaces the N+1 pattern of loading all meetings and filtering in memory.
  """
  @spec list_cancelled_meetings_for_user(String.t()) :: [Meeting.t()]
  def list_cancelled_meetings_for_user(user_email) do
    Meeting
    |> with_status("cancelled")
    |> for_user_email(user_email)
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Get meetings for a user with pagination support and proper filtering.
  This is a more flexible version that supports different statuses and time filters.
  """
  @spec list_meetings_for_user_paginated(String.t(), Keyword.t()) :: [Meeting.t()]
  def list_meetings_for_user_paginated(user_email, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 20)
    status = Keyword.get(opts, :status)
    # :upcoming, :past, or nil for all
    time_filter = Keyword.get(opts, :time_filter)

    now = DateTime.utc_now()

    Meeting
    |> for_user_email(user_email)
    |> with_status(status)
    |> apply_time_filter(time_filter, now)
    |> order_by_start_desc()
    |> paginate_offset(page, per_page)
    |> Repo.all()
  end

  @doc """
  Cursor-based pagination for a user's meetings using keyset on start_time and id.
  Accepts opts: :after_start (DateTime), :after_id (binary_id), :per_page, :status, :time_filter (:upcoming | :past).
  Returns a list limited to per_page.
  """
  @spec list_meetings_for_user_paginated_cursor(String.t(), Keyword.t()) :: [Meeting.t()]
  def list_meetings_for_user_paginated_cursor(user_email, opts \\ []) do
    after_start = Keyword.get(opts, :after_start)
    after_id = Keyword.get(opts, :after_id)
    per_page = Keyword.get(opts, :per_page, 20)
    # Fetch one extra item to determine if there's a next page
    limit = per_page + 1
    status = Keyword.get(opts, :status)
    exclude_status = Keyword.get(opts, :exclude_status)
    time_filter = Keyword.get(opts, :time_filter)

    now = DateTime.utc_now()

    Meeting
    |> for_user_email(user_email)
    |> with_status(status)
    |> without_status(exclude_status)
    |> apply_time_filter(time_filter, now)
    |> order_by_start_desc_id_desc()
    |> cursor_after(after_start, after_id)
    |> apply_limit(limit)
    |> Repo.all()
  end
end
