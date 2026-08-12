defmodule Tymeslot.Meetings.MeetingAccess do
  @moduledoc """
  Authorized retrieval and mutation of meetings by ID or UID.

  Every lookup here either scopes the query to the requesting user (as
  organizer or attendee) or authorizes the caller before returning or
  mutating the meeting, so callers never need to re-check ownership
  themselves. Use `MeetingQueries` directly only for unscoped, internal
  reads (e.g. background jobs already holding a trusted meeting ID).
  """

  alias Tymeslot.Meetings.{MeetingQueries, MeetingSchema}

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
end
