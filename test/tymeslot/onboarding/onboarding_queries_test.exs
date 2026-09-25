defmodule Tymeslot.Onboarding.OnboardingQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Onboarding.OnboardingQueries
  alias Tymeslot.Repo

  describe "mark_dashboard_tour_seen/1" do
    test "sets dashboard_tour_seen_at to now for a user that hasn't seen the tour" do
      user = insert(:user, dashboard_tour_seen_at: nil)

      assert {:ok, updated} = OnboardingQueries.mark_dashboard_tour_seen(user)
      assert %DateTime{} = updated.dashboard_tour_seen_at
    end

    test "overwrites an existing timestamp — this write is unconditional" do
      # Idempotence is not a property of this query: it lives one layer up in
      # Onboarding.mark_dashboard_tour_seen/1, which short-circuits when the
      # tour has already been seen. Here a stale stamp is always replaced.
      previously_seen = DateTime.add(DateTime.utc_now(:second), -365, :day)
      user = insert(:user, dashboard_tour_seen_at: previously_seen)

      assert {:ok, updated} = OnboardingQueries.mark_dashboard_tour_seen(user)

      assert DateTime.compare(updated.dashboard_tour_seen_at, previously_seen) == :gt
      assert DateTime.diff(DateTime.utc_now(), updated.dashboard_tour_seen_at, :second) <= 5
      assert Repo.reload!(user).dashboard_tour_seen_at == updated.dashboard_tour_seen_at
    end
  end
end
