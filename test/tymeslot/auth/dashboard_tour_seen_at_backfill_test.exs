defmodule Tymeslot.Auth.DashboardTourSeenAtBackfillTest do
  @moduledoc false
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations

  alias Tymeslot.Repo

  test "backfill SQL sets dashboard_tour_seen_at only for fully-onboarded users" do
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

    # Simulate the migration's backfill statement.
    Repo.query!(
      "UPDATE users SET dashboard_tour_seen_at = NOW() WHERE onboarding_completed_at IS NOT NULL"
    )

    assert %DateTime{} = Repo.reload!(fully_onboarded).dashboard_tour_seen_at
    refute Repo.reload!(mid_onboarding).dashboard_tour_seen_at
  end
end
