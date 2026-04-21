defmodule Tymeslot.Auth.RegistrationCompositionTest do
  @moduledoc """
  End-to-end composition coverage for
  `Tymeslot.Auth.Registration.register_user/3`.

  The unit suite (`registration_test.exs`) covers validation paths and
  password hashing. This file exercises the full pipeline:

    validate input →
    check rate limit →
    create user →
    create profile →
    create default weekly schedule (7 rows) →
    broadcast `:user_registered` on PubSub

  The critical invariant here — asserted nowhere else — is that a
  successfully registered user ends up with **both** a profile row
  **and** a complete default weekly schedule, because the downstream
  availability calculations are silent no-ops when the schedule is
  missing.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integration

  alias Tymeslot.Auth.Registration
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "auth:user_registered")

    RateLimiter.clear_all()

    on_exit(fn -> RateLimiter.clear_all() end)

    :ok
  end

  describe "register_user/3 — full pipeline" do
    test "creates user, profile, weekly schedule, and broadcasts :user_registered" do
      email = "composition-#{System.unique_integer([:positive])}@example.com"

      params = %{
        "email" => email,
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => "Composition User",
        "name" => "Composition User",
        "terms_accepted" => "true"
      }

      assert {:ok, user, message} =
               Registration.register_user(params, %Plug.Conn{},
                 metadata: %{source: "composition-test"}
               )

      assert message =~ "Account created"
      assert user.email == email
      # Users go through email verification — they start unverified.
      assert is_nil(user.verified_at)
      assert String.starts_with?(user.password_hash, "$2b$")

      # Profile row is written and linked to the user.
      assert %ProfileSchema{} = profile = Repo.get_by(ProfileSchema, user_id: user.id)

      # Default weekly schedule has one row per day (Mon..Sun = 1..7).
      weekly_rows =
        WeeklyAvailabilitySchema
        |> Repo.all()
        |> Enum.filter(&(&1.profile_id == profile.id))
        |> Enum.sort_by(& &1.day_of_week)

      assert length(weekly_rows) == 7
      assert Enum.map(weekly_rows, & &1.day_of_week) == Enum.to_list(1..7)

      # Weekdays are available by default; weekends are not.
      weekday_rows = Enum.filter(weekly_rows, &(&1.day_of_week in 1..5))
      weekend_rows = Enum.filter(weekly_rows, &(&1.day_of_week in 6..7))
      assert Enum.all?(weekday_rows, & &1.is_available)
      refute Enum.any?(weekend_rows, & &1.is_available)

      # PubSub event for cross-app listeners (SaaS, etc.).
      assert_received {:user_registered, %{user: broadcast_user, metadata: metadata}}
      assert broadcast_user.id == user.id
      assert metadata == %{source: "composition-test"}
    end
  end

  describe "register_user/3 — rate limit refuses creation" do
    test "does not create a user when the signup rate limit is already exhausted" do
      email = "rate-#{System.unique_integer([:positive])}@example.com"
      # Burn through the 10-minute / 5-attempt signup bucket for this email.
      for _i <- 1..5 do
        RateLimiter.check_signup_rate_limit(email, nil)
      end

      params = %{
        "email" => email,
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "full_name" => "Rate Limited",
        "name" => "Rate Limited",
        "terms_accepted" => "true"
      }

      assert {:error, :rate_limited, _message} =
               Registration.register_user(params, %Plug.Conn{})

      # No user row was created despite the matching password and terms.
      refute Repo.get_by(UserSchema, email: email)
      refute_received {:user_registered, _payload}
    end
  end
end
