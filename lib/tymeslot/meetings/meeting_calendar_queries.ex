defmodule Tymeslot.Meetings.MeetingCalendarQueries do
  @moduledoc """
  Database queries for calendar integration lookups and sync-status management.

  Handles finding meetings by external provider identifiers and updating the
  `calendar_sync_status` field that tracks divergence between Tymeslot and an
  external calendar provider.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  @valid_sync_statuses ~w(externally_deleted externally_modified)

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
  Returns a map from `provider_event_id` to meeting for all meetings linked to the
  given integration whose `provider_event_id` is in the supplied list.

  Events with a `nil` provider_event_id are silently excluded because they cannot
  be keyed. Use this instead of `get_by_provider_event_id/2` in loops to avoid
  N+1 queries.
  """
  @spec list_by_provider_event_ids(integer(), [String.t()]) :: %{String.t() => Meeting.t()}
  def list_by_provider_event_ids(_calendar_integration_id, []), do: %{}

  def list_by_provider_event_ids(calendar_integration_id, provider_event_ids)
      when is_list(provider_event_ids) do
    ids = Enum.reject(provider_event_ids, &is_nil/1)

    if ids == [] do
      %{}
    else
      Meeting
      |> where(
        [m],
        m.calendar_integration_id == ^calendar_integration_id and
          m.provider_event_id in ^ids
      )
      |> Repo.all()
      |> Map.new(&{&1.provider_event_id, &1})
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
  Updates `calendar_sync_status` on a meeting and clears `calendar_sync_status_dismissed_at`.

  `status` must be one of `"externally_deleted"` or `"externally_modified"`.

  Returns `{:ok, meeting}` on success or `{:error, :not_found}` if no row matched.
  """
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
      MeetingQueries.get_meeting(meeting_id)
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
