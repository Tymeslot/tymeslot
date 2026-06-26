defmodule Tymeslot.Meetings.AttachmentSnapshotQueries do
  @moduledoc """
  Queries over the `attachments_snapshot` captured on meetings at booking time.

  Kept separate from `MeetingQueries` so the snapshot-reference lookup that
  guards attachment file deletion has a focused home.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  @doc """
  Returns true if any meeting's `attachments_snapshot` still contains an entry
  whose `stored_path` matches the given value.

  Used to guard physical file deletion when a host removes a meeting-type
  attachment: if past bookings snapshotted the file, the on-disk copy must be
  kept so their calendar events and confirmation emails continue to resolve.
  """
  @spec attachment_path_referenced?(String.t()) :: boolean()
  def attachment_path_referenced?(stored_path) when is_binary(stored_path) do
    Repo.exists?(
      from(m in Meeting,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?::jsonb[]) AS e WHERE e->>'stored_path' = ?)",
            m.attachments_snapshot,
            ^stored_path
          )
      )
    )
  end
end
