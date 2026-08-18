defmodule Tymeslot.Auth.DashboardTourSeenAtBackfillTest do
  @moduledoc """
  Drives `20260519102624_add_dashboard_tour_seen_at_to_users`: its backfill
  marks the tour seen for users who finished onboarding before the column
  existed, and leaves everyone still mid-onboarding to see it.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_519_102_624

  test "backfill sets dashboard_tour_seen_at only for fully-onboarded users" do
    fully_onboarded =
      insert(:user,
        email: "completed@example.com",
        onboarding_completed_at: DateTime.utc_now(:second),
        dashboard_tour_seen_at: nil
      )

    mid_onboarding =
      insert(:user,
        email: "midway@example.com",
        onboarding_completed_at: nil,
        dashboard_tour_seen_at: nil
      )

    # `up/0` adds the column, so the round trip has to drop it first. Neither
    # user carries a stamp to lose.
    MigrationRunner.rerun!(@version)

    assert %DateTime{} = Repo.reload!(fully_onboarded).dashboard_tour_seen_at
    refute Repo.reload!(mid_onboarding).dashboard_tour_seen_at
  end
end
