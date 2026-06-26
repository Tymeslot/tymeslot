defmodule Tymeslot.Meetings.MeetingQueries do
  @moduledoc """
  Database queries for Meeting schema.

  This module provides a clean interface for single-record access, writes,
  and aggregate counts on meetings. Listing, filtering, and pagination
  queries live in `Tymeslot.Meetings.MeetingListQueries`. Business logic
  should be handled in the `Tymeslot.Meetings` context module.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

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
  Returns the count of bookings created for an organizer within the given
  window. Used by the analytics dashboard to compute conversion rate.
  """
  @spec count_bookings(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_bookings(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns the count of bookings grouped by `utm_source` for an organizer
  within the given window. Only returns rows where `utm_source` is set.
  Intended as a primitive for analytics composition — callers should not
  interpret the shape; use `Tymeslot.Analytics.attribution_table/3` instead.
  """
  @spec count_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), bookings: non_neg_integer()}
        ]
  def count_by_utm_source(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.utm_source))
    |> group_by([m], m.utm_source)
    |> select([m], %{utm_source: m.utm_source, bookings: count(m.id)})
    |> Repo.all()
  end

  @doc """
  Counts distinct converting visitors (meetings carrying a `visitor_hash`) for
  an organizer within the window. See `Tymeslot.Meetings.count_converting_visitors/3`.
  """
  @spec count_converting_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_converting_visitors(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.visitor_hash))
    |> select([m], count(m.visitor_hash, :distinct))
    |> Repo.one() || 0
  end

  @doc """
  Returns distinct converting-visitor counts grouped by `utm_source` for an
  organizer within the window. Only rows where both `utm_source` and
  `visitor_hash` are set.
  """
  @spec converting_visitors_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), converting_visitors: non_neg_integer()}
        ]
  def converting_visitors_by_utm_source(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.utm_source))
    |> where([m], not is_nil(m.visitor_hash))
    |> group_by([m], m.utm_source)
    |> select([m], %{
      utm_source: m.utm_source,
      converting_visitors: count(m.visitor_hash, :distinct)
    })
    |> Repo.all()
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
end
