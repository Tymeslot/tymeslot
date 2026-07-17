defmodule Tymeslot.Meetings.RescheduleRequestedAtBackfillTest do
  @moduledoc """
  Verifies the up/down backfill SQL from
  `20260716094322_add_reschedule_requested_at_to_meetings`: `up` splits the
  legacy `status = "reschedule_requested"` overload into the
  `reschedule_requested_at` column without touching other statuses, and
  `down` only resurrects the still-active (non-terminal) rows it created —
  it must never clobber a cancelled or completed meeting that happens to
  carry a stale `reschedule_requested_at`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :meetings

  alias Tymeslot.Repo

  @up_sql """
  UPDATE meetings
  SET reschedule_requested_at = updated_at,
      status = 'confirmed'
  WHERE status = 'reschedule_requested'
  """

  @down_sql """
  UPDATE meetings
  SET status = 'reschedule_requested'
  WHERE reschedule_requested_at IS NOT NULL
    AND status IN ('confirmed', 'pending', 'awaiting_payment')
  """

  describe "up" do
    test "converts reschedule_requested rows and leaves other statuses untouched" do
      requested = insert(:meeting, status: "reschedule_requested")
      pending = insert(:meeting, status: "pending")
      confirmed = insert(:meeting, status: "confirmed")

      Repo.query!(@up_sql)

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

      Repo.query!(@down_sql)

      assert Repo.reload!(confirmed).status == "reschedule_requested"
      assert Repo.reload!(pending).status == "reschedule_requested"
      assert Repo.reload!(awaiting_payment).status == "reschedule_requested"
      assert Repo.reload!(cancelled).status == "cancelled"
      assert Repo.reload!(completed).status == "completed"
    end
  end
end
