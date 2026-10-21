defmodule Tymeslot.Migrations.AddConfirmationToPollParticipantsTest do
  @moduledoc """
  Value-correctness regression for `add_confirmation_to_poll_participants`,
  which brings email confirmation to poll participants.

  The decisive properties: everyone already on a poll is confirmed, from the
  time of their vote if they voted and from when they joined otherwise, and
  rolling back deletes the link requests nobody confirmed, so the previous
  release, which counts every participant, never counts one of them.

  Driven from `priv` with `MigrationRunner`: `rerun!/2` takes the migration
  down and back up, so `up/0` meets participants as the previous release
  left them.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :polls

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_021_145_354

  @joined ~U[2026-10-01 09:00:00Z]
  @voted ~U[2026-10-02 10:30:00Z]

  describe "up" do
    test "confirms a participant who voted from the time of their vote" do
      voter = legacy_participant(voted_at: @voted)

      MigrationRunner.rerun!(@version)

      assert Repo.reload!(voter).confirmed_at == @voted
    end

    test "confirms a participant who never voted from when they joined" do
      silent = legacy_participant([])

      MigrationRunner.rerun!(@version)

      assert Repo.reload!(silent).confirmed_at == @joined
    end
  end

  describe "down" do
    test "deletes pending link requests and keeps everyone who counts" do
      poll = insert(:poll)

      voter =
        insert(:poll_participant,
          poll: poll,
          confirmed_at: @voted,
          invited_at: nil,
          voted_at: @voted
        )

      invitee = insert(:poll_participant, poll: poll, confirmed_at: @joined, invited_at: @joined)

      _pending =
        insert(:poll_participant,
          poll: poll,
          confirmed_at: nil,
          invited_at: nil,
          link_sent_at: DateTime.utc_now(:second)
        )

      MigrationRunner.down!(@version)

      assert participant_ids(poll.id) == Enum.sort([voter.id, invitee.id])
      refute column?("confirmed_at")
      refute column?("link_sent_at")
    end
  end

  # Someone on a poll from before confirmation: never invited, since that
  # release had no invitations, and joined well before any vote.
  defp legacy_participant(attrs) do
    insert(
      :poll_participant,
      Keyword.merge([inserted_at: @joined, confirmed_at: @joined, invited_at: nil], attrs)
    )
  end

  # The schema still names the dropped columns, so after `down/0` the rows are
  # read with plain SQL.
  defp participant_ids(poll_id) do
    %{rows: rows} =
      Repo.query!("SELECT id FROM poll_participants WHERE poll_id = $1", [UUID.dump!(poll_id)])

    rows |> Enum.map(fn [id] -> UUID.load!(id) end) |> Enum.sort()
  end

  defp column?(name) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_name = 'poll_participants' AND column_name = $1
        """,
        [name]
      )

    count == 1
  end
end
