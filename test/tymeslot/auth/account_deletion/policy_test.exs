defmodule Tymeslot.Auth.AccountDeletion.PolicyTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Auth.AccountDeletion.Policy
  alias Tymeslot.Profiles.ProfileSchema

  describe "local_date/2" do
    test "is the user's own calendar day, which can differ from the UTC one" do
      at = ~U[2026-10-16 23:30:00Z]

      assert Policy.local_date(at, "Europe/Tallinn") == ~D[2026-10-17]
      assert Policy.local_date(at, "America/Los_Angeles") == ~D[2026-10-16]
    end

    test "falls back to the UTC date without a usable timezone" do
      at = ~U[2026-10-16 23:30:00Z]

      assert Policy.local_date(at, nil) == ~D[2026-10-16]
      assert Policy.local_date(at, "Not/AZone") == ~D[2026-10-16]
    end
  end

  describe "user_local_date/2" do
    # 23:30 UTC is already the next day on the default zone, Europe/Tallinn.
    @at ~U[2026-10-16 23:30:00Z]

    test "reads the day on the profile's zone" do
      profile = insert(:profile, timezone: "America/Los_Angeles")

      assert Policy.user_local_date(@at, profile.user_id) == ~D[2026-10-16]
    end

    for {label, stored} <- [{"no", nil}, {"a blank", ""}, {"an unknown", "Not/AZone"}] do
      test "reads the day on the default zone for a profile with #{label} timezone" do
        profile = insert(:profile)

        Repo.update_all(from(p in ProfileSchema, where: p.id == ^profile.id),
          set: [timezone: unquote(stored)]
        )

        assert Policy.user_local_date(@at, profile.user_id) == ~D[2026-10-17]
      end
    end

    test "reads the day on the default zone for a user with no profile" do
      user = insert(:user)

      assert Policy.user_local_date(@at, user.id) == ~D[2026-10-17]
    end
  end

  describe "grace_days/0 and scheduled_at/1" do
    test "defaults to zero days, so the deletion is due straight away" do
      with_config(:tymeslot, :account_deletion_grace_days, 0)
      now = ~U[2026-10-02 10:00:00Z]

      assert Policy.grace_days() == 0
      assert Policy.immediate?()
      assert Policy.scheduled_at(now) == now
    end

    test "adds the configured grace period" do
      with_config(:tymeslot, :account_deletion_grace_days, 14)

      refute Policy.immediate?()
      assert Policy.scheduled_at(~U[2026-10-02 10:00:00Z]) == ~U[2026-10-16 10:00:00Z]
    end

    test "treats a nonsensical value as zero" do
      with_config(:tymeslot, :account_deletion_grace_days, -3)
      assert Policy.grace_days() == 0
    end
  end

  describe "normalise_feedback/1" do
    test "returns nothing while feedback collection is off" do
      with_config(:tymeslot, :collect_deletion_feedback, false)
      assert Policy.normalise_feedback(%{"reason" => "too_expensive"}) == nil
    end

    test "keeps a known reason and a trimmed, capped comment" do
      with_config(:tymeslot, :collect_deletion_feedback, true)
      long = String.duplicate("a", 600)

      assert Policy.normalise_feedback(%{"reason" => "too_expensive", "comment" => "  " <> long}) ==
               %{reason: "too_expensive", comment: String.duplicate("a", 500)}
    end

    test "drops an unknown reason, and a blank comment becomes nil" do
      with_config(:tymeslot, :collect_deletion_feedback, true)

      assert Policy.normalise_feedback(%{"reason" => "made_up", "comment" => "x"}) == nil

      assert Policy.normalise_feedback(%{"reason" => "other", "comment" => " \u0000 "}) ==
               %{reason: "other", comment: nil}
    end
  end

  describe "confirmation_method/1" do
    test "an account with a password hash confirms with its password" do
      assert Policy.confirmation_method(%{password_hash: "hash"}) == :password
      assert Policy.confirmation_method(%{provider: "google", password_hash: "hash"}) == :password
    end

    test "an account without one confirms with its address, whatever its provider" do
      assert Policy.confirmation_method(%{provider: "google", password_hash: nil}) == :email
      assert Policy.confirmation_method(%{provider: "email", password_hash: nil}) == :email
      assert Policy.confirmation_method(%{provider: nil, password_hash: ""}) == :email
    end
  end
end
