defmodule Tymeslot.Repo.Migrations.ScopeMeetingGuestsToParticipantsTest do
  @moduledoc """
  The migration swaps the single `(meeting_id, email)` guest uniqueness for
  one partial index per booking shape. A database that collected duplicate
  guests some other way (a restore, a hand-dropped index) must be repaired
  first, keeping the oldest guest of each duplicate set, rather than failing
  halfway through the swap.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :migrations

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_002_161_422

  defp insert_raw_guest(meeting_id, email, inserted_at) do
    id = UUID.generate()

    Repo.query!(
      """
      INSERT INTO meeting_guests (id, meeting_id, email, status, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'pending', $4, $4)
      """,
      [UUID.dump!(id), UUID.dump!(meeting_id), email, inserted_at]
    )

    id
  end

  defp guest_ids do
    %{rows: rows} = Repo.query!("SELECT id FROM meeting_guests")
    rows |> Enum.map(fn [id] -> UUID.load!(id) end) |> MapSet.new()
  end

  defp index_definitions do
    %{rows: rows} =
      Repo.query!("SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'meeting_guests'")

    Map.new(rows, fn [name, definition] -> {name, definition} end)
  end

  test "keeps the oldest of each duplicate guest and swaps in the per-booker indexes" do
    MigrationRunner.down!(@version)

    # A database whose unique index went missing, so duplicates got in.
    Repo.query!("DROP INDEX meeting_guests_meeting_id_email_index")

    meeting = insert(:meeting)
    other_meeting = insert(:meeting)
    earlier = ~U[2026-01-01 09:00:00Z]
    later = ~U[2026-01-02 09:00:00Z]

    kept = insert_raw_guest(meeting.id, "dup@example.com", earlier)
    _dropped = insert_raw_guest(meeting.id, "dup@example.com", later)
    _dropped_too = insert_raw_guest(meeting.id, "dup@example.com", later)
    unique = insert_raw_guest(meeting.id, "solo@example.com", later)
    elsewhere = insert_raw_guest(other_meeting.id, "dup@example.com", later)

    MigrationRunner.up!(@version)

    assert guest_ids() == MapSet.new([kept, unique, elsewhere])

    indexes = index_definitions()
    refute Map.has_key?(indexes, "meeting_guests_meeting_id_email_index")

    assert indexes["meeting_guests_meeting_id_email_solo_index"] =~
             ~r/UNIQUE INDEX .*\(meeting_id, email\) WHERE \(participant_id IS NULL\)/

    assert indexes["meeting_guests_participant_id_email_index"] =~
             ~r/UNIQUE INDEX .*\(meeting_id, participant_id, email\) WHERE \(participant_id IS NOT NULL\)/
  end
end
