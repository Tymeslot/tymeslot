defmodule Tymeslot.Meetings.MeetingQueries do
  @moduledoc """
  Database queries for Meeting schema.

  This module provides a clean interface for all database operations
  related to meetings. It focuses on pure data access - business logic
  should be handled in the Tymeslot.Meetings context module.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  # Query building helpers

  defp for_user_email(query, email),
    do: from(m in query, where: m.organizer_email == ^email or m.attendee_email == ^email)

  defp for_attendee_email(query, email),
    do: from(m in query, where: m.attendee_email == ^email)

  defp for_organizer_email(query, email),
    do: from(m in query, where: m.organizer_email == ^email)

  defp with_status(query, nil), do: query
  defp with_status(query, status), do: from(m in query, where: m.status == ^status)

  defp without_status(query, nil), do: query
  defp without_status(query, ""), do: query

  defp without_status(query, status) when is_list(status),
    do: from(m in query, where: m.status not in ^status)

  defp without_status(query, status), do: from(m in query, where: m.status != ^status)

  defp upcoming(query, now), do: from(m in query, where: m.end_time > ^now)
  defp past(query, now), do: from(m in query, where: m.end_time < ^now)
  defp order_by_start_desc(query), do: from(m in query, order_by: [desc: m.start_time])
  defp order_by_start_asc(query), do: from(m in query, order_by: [asc: m.start_time])

  defp paginate_offset(query, page, per_page),
    do: from(m in query, limit: ^per_page, offset: ^((page - 1) * per_page))

  defp apply_limit(query, limit), do: from(m in query, limit: ^limit)

  defp apply_time_filter(query, nil, _now), do: query
  defp apply_time_filter(query, :upcoming, now), do: upcoming(query, now)
  defp apply_time_filter(query, :past, now), do: past(query, now)

  defp cursor_after(query, nil, _after_id), do: query
  defp cursor_after(query, _after_start, nil), do: query

  defp cursor_after(query, after_start, after_id) do
    from(m in query,
      where:
        m.start_time < ^after_start or
          (m.start_time == ^after_start and m.id < ^after_id)
    )
  end

  defp order_by_start_desc_id_desc(query),
    do: from(m in query, order_by: [desc: m.start_time, desc: m.id])

  @doc "Creates a meeting."
  @spec create_meeting(map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def create_meeting(attrs \\ %{}) when is_map(attrs) do
    %Meeting{}
    |> Meeting.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Gets a single meeting by ID."
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

  @doc "Gets a single meeting by UID."
  @spec get_meeting_by_uid(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid(uid) do
    case Repo.get_by(Meeting, uid: uid) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Fetches a meeting by UID only if the given `organizer_user_id` owns it.

  Returns `{:ok, meeting}` when a matching meeting is found.
  Returns `{:error, :not_found}` when no meeting exists with that UID, or when
  the meeting exists but belongs to a different organizer.
  """
  @spec get_meeting_by_uid_for_organizer(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid_for_organizer(uid, organizer_user_id)
      when is_integer(organizer_user_id) do
    query =
      from(m in Meeting,
        where: m.uid == ^uid and m.organizer_user_id == ^organizer_user_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc "Updates a meeting."
  @spec update_meeting(Meeting.t(), map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def update_meeting(%Meeting{} = meeting, attrs) when is_map(attrs) do
    meeting
    |> Meeting.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Writes a new attendee-notification baseline for a meeting, updating both the
  serialised `last_notified_state` snapshot and `ical_sequence` atomically.
  """
  @spec update_notification_baseline(Meeting.t(), map(), non_neg_integer()) ::
          {:ok, Meeting.t()} | {:error, Changeset.t()}
  def update_notification_baseline(%Meeting{} = meeting, state, sequence)
      when is_map(state) and is_integer(sequence) do
    meeting
    |> Changeset.change(last_notified_state: state, ical_sequence: sequence)
    |> Repo.update()
  end

  @doc "Deletes a meeting."
  @spec delete_meeting(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def delete_meeting(%Meeting{} = meeting) do
    Repo.delete(meeting)
  end

  @doc """
  Returns the list of all meetings.
  """
  @spec list_meetings() :: [Meeting.t()]
  def list_meetings do
    Meeting
    |> order_by_start_desc()
    |> Repo.all()
  end

  @doc """
  Returns the list of meetings with a specific status.
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

  Accepts a map with `value` (integer) and `unit` (string) keys representing
  an already-normalised reminder. Callers are responsible for validation.
  """
  @spec append_reminder_sent(Meeting.t(), %{value: integer(), unit: String.t()}) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def append_reminder_sent(%Meeting{} = meeting, %{value: val, unit: unit}) do
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
  Returns the count of meetings with status `awaiting_payment` for a given organizer.

  Used by `Tymeslot.MeetingPayments` to guard currency changes: if the host has any
  meetings waiting for payment, the currency cannot be changed until they are resolved.
  """
  @spec count_awaiting_payment_for_organizer(integer()) :: non_neg_integer()
  def count_awaiting_payment_for_organizer(organizer_user_id) do
    Repo.aggregate(
      from(m in Meeting,
        where: m.organizer_user_id == ^organizer_user_id and m.status == "awaiting_payment"
      ),
      :count,
      :id
    )
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
  Returns upcoming meetings that should have a video room link but do not.
  """
  @spec list_meetings_missing_video_rooms(DateTime.t(), pos_integer()) :: [Meeting.t()]
  def list_meetings_missing_video_rooms(now, limit \\ 500) do
    now
    |> meetings_missing_video_rooms_base()
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns the given user's upcoming meetings that should have a video room link
  but do not. Used to retry video room creation immediately after the user
  re-authorises their video provider integration with the right scope.
  """
  @spec list_user_meetings_missing_video_rooms(pos_integer(), DateTime.t(), pos_integer()) ::
          [Meeting.t()]
  def list_user_meetings_missing_video_rooms(user_id, now, limit \\ 500) do
    now
    |> meetings_missing_video_rooms_base()
    |> where([m], m.organizer_user_id == ^user_id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp meetings_missing_video_rooms_base(now) do
    Meeting
    |> with_status("confirmed")
    |> upcoming(now)
    |> where([m], not is_nil(m.video_integration_id))
    |> where([m], is_nil(m.video_room_id))
    |> order_by([m], asc: m.start_time)
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
