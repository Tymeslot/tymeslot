defmodule Tymeslot.DatabaseQueries.MeetingQueries do
  @moduledoc """
  Database queries for Meeting schema.

  This module provides a clean interface for all database operations
  related to meetings. It focuses on pure data access - business logic
  should be handled in the Tymeslot.Meetings context module.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.DatabaseSchemas.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

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
  # Private helper: filter upcoming meetings strictly after the provided timestamp.
  defp upcoming(query, now), do: from(m in query, where: m.start_time > ^now)

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
    case Repo.get(Meeting, id) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
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
  Gets a single meeting by ID for a specific user.
  This is the secure version that checks user authorization.
  A user can access a meeting if they are the organizer OR the attendee.
  Returns {:ok, meeting} if found and authorized, {:error, :not_found} otherwise.
  """
  @spec get_meeting_for_user(String.t(), String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_for_user(id, user_email) when is_binary(user_email) do
    query =
      from(m in Meeting,
        where:
          m.id == ^id and (m.organizer_email == ^user_email or m.attendee_email == ^user_email)
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Gets a single meeting by UID for a specific user.
  This is the secure version that checks user authorization.
  Returns {:ok, meeting} if found and authorized, {:error, :not_found} otherwise.
  """
  @spec get_meeting_by_uid_for_user(String.t(), String.t()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid_for_user(uid, user_email) when is_binary(user_email) do
    query =
      from(m in Meeting,
        where:
          m.uid == ^uid and (m.organizer_email == ^user_email or m.attendee_email == ^user_email)
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Updates a meeting for a specific user.
  Only the organizer can update a meeting.
  Returns {:ok, meeting} if authorized and updated, {:error, :unauthorized} if not authorized.
  """
  @spec update_meeting_for_user(Meeting.t(), map(), String.t()) ::
          {:ok, Meeting.t()} | {:error, :unauthorized | Changeset.t()}
  def update_meeting_for_user(%Meeting{} = meeting, attrs, user_email)
      when is_binary(user_email) do
    if meeting.organizer_email == user_email do
      update_meeting(meeting, attrs)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Deletes a meeting for a specific user.
  Only the organizer can delete a meeting.
  Returns {:ok, meeting} if authorized and deleted, {:error, :unauthorized} if not authorized.
  """
  @spec delete_meeting_for_user(Meeting.t(), String.t()) ::
          {:ok, Meeting.t()} | {:error, :unauthorized | Changeset.t()}
  def delete_meeting_for_user(%Meeting{} = meeting, user_email) when is_binary(user_email) do
    if meeting.organizer_email == user_email do
      delete_meeting(meeting)
    else
      {:error, :unauthorized}
    end
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
        _ -> nil
      end

    if attrs do
      update_meeting(meeting, attrs)
    else
      {:error, :invalid_email_type}
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
  Returns meetings that need reminder emails sent.
  This is a data access function that queries meetings by time window and status.
  Business logic for determining which meetings need reminders should be in the Meetings context.
  """
  @spec list_meetings_needing_reminders(DateTime.t(), DateTime.t()) :: [Meeting.t()]
  def list_meetings_needing_reminders(start_time, end_time) do
    query =
      from(m in Meeting,
        where:
          m.start_time >= ^start_time and
            m.start_time <= ^end_time and
            m.reminder_email_sent == false and
            m.status == "confirmed",
        order_by: [asc: m.start_time]
      )

    Repo.all(query)
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
  Get all meetings for a user with filters and preloads.
  Supports pagination. Takes user_id and looks up user's email.
  """
  @spec user_meetings(String.t() | integer(), Keyword.t()) :: [Meeting.t()]
  def user_meetings(user_id, opts \\ []) do
    case UserQueries.get_user(user_id) do
      {:error, :not_found} ->
        []

      {:ok, user} ->
        page = Keyword.get(opts, :page, 1)
        per_page = Keyword.get(opts, :per_page, 20)
        status = Keyword.get(opts, :status)

        Meeting
        |> for_user_email(user.email)
        |> with_status(status)
        |> order_by_start_desc()
        |> paginate_offset(page, per_page)
        |> Repo.all()
    end
  end

  @doc """
  Count total meetings for pagination.
  Takes user_id and looks up user's email.
  """
  @spec count_user_meetings(String.t() | integer(), Keyword.t()) :: non_neg_integer()
  def count_user_meetings(user_id, opts \\ []) do
    case UserQueries.get_user(user_id) do
      {:error, :not_found} ->
        0

      {:ok, user} ->
        status = Keyword.get(opts, :status)

        query =
          Meeting
          |> for_user_email(user.email)
          |> with_status(status)

        Repo.aggregate(query, :count, :id)
    end
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
    limit = Keyword.get(opts, :per_page, 20)
    status = Keyword.get(opts, :status)
    time_filter = Keyword.get(opts, :time_filter)

    now = DateTime.utc_now()

    Meeting
    |> for_user_email(user_email)
    |> with_status(status)
    |> apply_time_filter(time_filter, now)
    |> order_by_start_desc_id_desc()
    |> cursor_after(after_start, after_id)
    |> apply_limit(limit)
    |> Repo.all()
  end
end
