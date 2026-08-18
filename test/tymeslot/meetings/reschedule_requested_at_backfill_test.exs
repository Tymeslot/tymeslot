defmodule Tymeslot.Meetings.RescheduleRequestedAtBackfillTest do
  @moduledoc """
  Drives `20260716094322_add_reschedule_requested_at_to_meetings` itself: `up`
  splits the legacy `status = "reschedule_requested"` overload into the
  `reschedule_requested_at` column without touching other statuses, and `down`
  only resurrects the still-active (non-terminal) rows it created — it must
  never clobber a cancelled or completed meeting that happens to carry a stale
  `reschedule_requested_at`.

  The migration module is loaded from `priv` and run through
  `Ecto.Migrator`; see `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :meetings

  import Ecto.Query

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_716_094_322

  describe "up" do
    test "converts reschedule_requested rows and leaves other statuses untouched" do
      requested = insert(:meeting, status: "reschedule_requested")
      pending = insert(:meeting, status: "pending")
      confirmed = insert(:meeting, status: "confirmed")

      # None of these rows carries a `reschedule_requested_at`, so the `down`
      # half of the round trip is a no-op on them and `up` meets the schema as
      # it stood before the migration.
      MigrationRunner.rerun!(@version)

      reloaded_requested = Repo.reload!(requested)
      assert reloaded_requested.status == "confirmed"

      assert DateTime.compare(reloaded_requested.reschedule_requested_at, requested.updated_at) ==
               :eq

      reloaded_pending = Repo.reload!(pending)
      assert reloaded_pending.status == "pending"
      refute reloaded_pending.reschedule_requested_at

      reloaded_confirmed = Repo.reload!(confirmed)
      assert reloaded_confirmed.status == "confirmed"
      refute reloaded_confirmed.reschedule_requested_at
    end
  end

  describe "down" do
    test "restores active timestamped rows and leaves cancelled/completed rows untouched" do
      now = DateTime.utc_now(:second)

      confirmed = insert(:meeting, status: "confirmed", reschedule_requested_at: now)
      pending = insert(:meeting, status: "pending", reschedule_requested_at: now)

      awaiting_payment =
        insert(:meeting, status: "awaiting_payment", reschedule_requested_at: now)

      cancelled = insert(:meeting, status: "cancelled", reschedule_requested_at: now)
      completed = insert(:meeting, status: "completed", reschedule_requested_at: now)

      MigrationRunner.down!(@version)

      assert status(confirmed) == "reschedule_requested"
      assert status(pending) == "reschedule_requested"
      assert status(awaiting_payment) == "reschedule_requested"
      assert status(cancelled) == "cancelled"
      assert status(completed) == "completed"
    end
  end

  # `down` drops `reschedule_requested_at`, so a full-row reload would ask for
  # a column that no longer exists.
  defp status(meeting) do
    Repo.one!(from(m in MeetingSchema, where: m.id == ^meeting.id, select: m.status))
  end
end
