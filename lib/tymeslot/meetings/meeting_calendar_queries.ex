defmodule Tymeslot.Meetings.MeetingCalendarQueries do
  @moduledoc """
  Database queries for calendar integration lookups and sync-status management.

  Handles finding meetings by external provider identifiers and updating the
  `calendar_sync_status` field that tracks divergence between Tymeslot and an
  external calendar provider.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.CalendarEventLink
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.GuestSchema, as: Guest
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Repo

  @externally_deleted "externally_deleted"
  @externally_modified "externally_modified"
  @valid_sync_statuses [@externally_deleted, @externally_modified]

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
  Returns the meetings linked to `calendar_integration_id` that share any of
  `identifiers`, keyed by **every** identifier each matched meeting carries.

  The keys are what makes this usable in a loop: a caller holding a cached
  provider event can look the meeting up under whichever identifier it has,
  without knowing which of the two the provider family populates. See
  `Tymeslot.Meetings.CalendarEventLink` for the identity rule.

  Blank identifiers are dropped — they cannot be keyed. Use this instead of
  `get_by_provider_event_id/2` in loops to avoid N+1 queries.
  """
  @spec list_by_calendar_identifiers(integer(), [String.t() | nil]) :: %{
          String.t() => Meeting.t()
        }
  def list_by_calendar_identifiers(_calendar_integration_id, []), do: %{}

  def list_by_calendar_identifiers(calendar_integration_id, identifiers)
      when is_list(identifiers) do
    case Enum.reject(identifiers, &CalendarEventLink.blank_identifier?/1) do
      [] ->
        %{}

      ids ->
        Meeting
        |> where(
          [m],
          m.calendar_integration_id == ^calendar_integration_id and
            (m.provider_event_id in ^ids or m.calendar_uid in ^ids)
        )
        |> Repo.all()
        |> Enum.flat_map(fn meeting ->
          Enum.map(CalendarEventLink.identifiers(meeting), &{&1, meeting})
        end)
        |> Map.new()
    end
  end

  @doc """
  Finds a meeting by the UID its calendar event carries (`calendar_uid`) and
  its calendar integration.

  Returns `{:ok, meeting}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_by_calendar_uid_and_integration(integer(), String.t()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_by_calendar_uid_and_integration(calendar_integration_id, calendar_uid) do
    result =
      Meeting
      |> where(
        [m],
        m.calendar_integration_id == ^calendar_integration_id and
          m.calendar_uid == ^calendar_uid
      )
      |> limit(1)
      |> Repo.one()

    case result do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Clears `calendar_sync_status` and `calendar_sync_status_dismissed_at` on a meeting.

  Returns `{:ok, meeting}` on success or `{:error, :not_found}` if no row matched.
  """
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
      MeetingQueries.get_meeting(meeting_id)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Clears `calendar_sync_status` on a meeting, but only while it reads
  `"externally_modified"`.

  Narrower than `clear_calendar_sync_status/1` on purpose: an
  `"externally_deleted"` meeting has already been auto-cancelled and its status
  is the record of why, so it must survive. Filtering in the `WHERE` rather
  than round-tripping the row keeps this safe to call for every event of a
  sync pass, which is how it is used — the overwhelmingly common outcome is
  that there was nothing to clear.

  Always returns `:ok`; a meeting that is not flagged, or no longer exists, is
  not an error at this call site.
  """
  @spec clear_external_modification(String.t()) :: :ok
  def clear_external_modification(meeting_id) do
    Meeting
    |> where([m], m.id == ^meeting_id and m.calendar_sync_status == @externally_modified)
    |> Repo.update_all(
      set: [
        calendar_sync_status: nil,
        calendar_sync_status_dismissed_at: nil,
        updated_at: DateTime.utc_now(:second)
      ]
    )

    :ok
  end

  @doc """
  Moves a meeting's end to `end_time`, with its duration, while its start is
  still the one the provider event was compared against and it still expects
  a provider event (`MeetingState.where_expects_calendar_event/1`). A meeting
  rescheduled, cancelled or sent a reschedule request in the meantime is left
  alone: the end was read against what it was before.

  The new end is the one the host's calendar shows, so it becomes the
  meeting's `seen_calendar_end_time` too.

  The new end is a new revision of every calendar entry that carries the
  meeting, so the meeting's `ical_sequence` advances, and so does each live
  group seat's, which is a calendar entry of its own: an update sent at an
  unchanged sequence is ignored by calendar clients.

  Every seat that will be told (the booker, each live participant, each live
  guest) keeps the end it knew as its `notified_end_time`, unless an earlier
  change is still unannounced, in which case it keeps the end it was last
  told. The row is locked first, so the end it knew is the one replaced here.

  Returns `{:ok, meeting}`, or `{:error, :not_found}` if no row matched.
  """
  @spec update_end_time(Meeting.t(), DateTime.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def update_end_time(%Meeting{id: id, start_time: start_time}, %DateTime{} = end_time) do
    Repo.transaction(fn ->
      previous_end =
        Meeting
        |> where([m], m.id == ^id and m.start_time == ^start_time)
        |> MeetingState.where_expects_calendar_event()
        |> lock("FOR UPDATE")
        |> select([m], m.end_time)
        |> Repo.one()

      if is_nil(previous_end), do: Repo.rollback(:not_found)

      Meeting
      |> where([m], m.id == ^id)
      |> update([m],
        set: [
          end_time: ^end_time,
          duration: ^DateTime.diff(end_time, start_time, :minute),
          notified_end_time: fragment("COALESCE(?, ?)", m.notified_end_time, ^previous_end),
          seen_calendar_end_time: ^end_time,
          updated_at: ^DateTime.utc_now(:second)
        ],
        inc: [ical_sequence: 1]
      )
      |> Repo.update_all([])

      ParticipantQueries.record_end_change(id, previous_end)
      GuestQueries.record_end_change(id, previous_end)

      case MeetingQueries.get_meeting(id) do
        {:ok, meeting} -> meeting
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Records `end_time` as the end the host's calendar event showed for the
  meeting at this sync (`seen_calendar_end_time`).
  """
  @spec put_seen_calendar_end(String.t(), DateTime.t()) :: :ok
  def put_seen_calendar_end(meeting_id, %DateTime{} = end_time) do
    Meeting
    |> where([m], m.id == ^meeting_id)
    |> Repo.update_all(set: [seen_calendar_end_time: end_time])

    :ok
  end

  @doc """
  Forgets every seat's `notified_end_time` (the booker's, each participant's,
  each guest's): the meeting's new times were just announced to all of them,
  so none has an end change left to hear about.
  """
  @spec clear_notified_ends(String.t()) :: :ok
  def clear_notified_ends(meeting_id) do
    for schema <- [Participant, Guest] do
      schema
      |> where([s], s.meeting_id == ^meeting_id and not is_nil(s.notified_end_time))
      |> Repo.update_all(set: [notified_end_time: nil])
    end

    Meeting
    |> where([m], m.id == ^meeting_id and not is_nil(m.notified_end_time))
    |> Repo.update_all(set: [notified_end_time: nil])

    :ok
  end

  @doc "Records that the booker has been told the meeting ends at `end_time`."
  @spec put_notified_end(String.t(), DateTime.t()) :: :ok
  def put_notified_end(meeting_id, %DateTime{} = end_time) do
    Meeting
    |> where([m], m.id == ^meeting_id)
    |> Repo.update_all(set: [notified_end_time: end_time])

    :ok
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

    if count > 0 do
      MeetingQueries.get_meeting(meeting_id)
    else
      # No rows updated — either already set or not found. A single existence
      # check is still needed but the TOCTOU window is narrower since we only
      # branch here when count == 0 (row was not mutated).
      if Repo.exists?(where(Meeting, [m], m.id == ^meeting_id)) do
        {:ok, :already_set}
      else
        {:error, :not_found}
      end
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
      MeetingQueries.get_meeting(meeting_id)
    else
      {:error, :not_found}
    end
  end
end
