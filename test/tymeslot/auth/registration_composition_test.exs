defmodule Tymeslot.Auth.RegistrationCompositionTest do
  @moduledoc """
  End-to-end composition coverage for
  `Tymeslot.Auth.Registration.register_user/2`.

  The unit suite (`registration_test.exs`) covers validation paths and
  password hashing. This file exercises the full pipeline:

    validate input →
    check rate limit →
    create user →
    create profile →
    create default availability schedule with its weekly days (7 rows) →
    enqueue the registration hook with the sign-up's metadata →
    broadcast `:user_registered` on PubSub

  The critical invariant here — asserted nowhere else — is that a
  successfully registered user ends up with **both** a profile row
  **and** a default availability schedule carrying a complete set of
  weekly days, because the downstream
  availability calculations are silent no-ops when the schedule is
  missing.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  alias Tymeslot.Auth
  alias Tymeslot.Auth.Registration
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.UserRegisteredHookWorker
  alias TymeslotWeb.Helpers.ClientIP

  defmodule NoopHook do
    @spec on_user_registered(pos_integer(), map()) :: :ok
    def on_user_registered(_user_id, _metadata), do: :ok
  end

  setup do
    :ok = Auth.subscribe_to_user_registrations()

    original_hook = Application.get_env(:tymeslot, :user_registered_hook)
    Application.put_env(:tymeslot, :user_registered_hook, NoopHook)

    on_exit(fn ->
      if original_hook,
        do: Application.put_env(:tymeslot, :user_registered_hook, original_hook),
        else: Application.delete_env(:tymeslot, :user_registered_hook)
    end)

    RateLimiter.clear_all()

    on_exit(fn -> RateLimiter.clear_all() end)

    :ok
  end

  describe "register_user/2 — full pipeline" do
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
               Registration.register_user(params,
                 ip: "203.0.113.41",
                 user_agent: "Composition/1.0"
               )

      assert message =~ "Account created"
      assert user.email == email
      # Users go through email verification — they start unverified.
      assert is_nil(user.verified_at)
      assert String.starts_with?(user.password_hash, "$2b$")

      # Profile row is written and linked to the user.
      assert %ProfileSchema{} = profile = Repo.get_by(ProfileSchema, user_id: user.id)

      # The profile owns exactly one default availability schedule.
      assert %{is_default: true} = schedule = Schedules.get_default(profile.id)

      # Default weekly schedule has one row per day (Mon..Sun = 1..7).
      weekly_rows =
        WeeklyAvailabilitySchema
        |> Repo.all()
        |> Enum.filter(&(&1.schedule_id == schedule.id))
        |> Enum.sort_by(& &1.day_of_week)

      assert length(weekly_rows) == 7
      assert Enum.map(weekly_rows, & &1.day_of_week) == Enum.to_list(1..7)

      # The two default meeting types are seeded with the profile, once.
      assert user.id |> MeetingTypes.get_all_meeting_types() |> Enum.map(& &1.name) |> Enum.sort() ==
               ["15 Minutes", "30 Minutes"]

      # Weekdays are available by default; weekends are not.
      weekday_rows = Enum.filter(weekly_rows, &(&1.day_of_week in 1..5))
      weekend_rows = Enum.filter(weekly_rows, &(&1.day_of_week in 6..7))
      assert Enum.all?(weekday_rows, & &1.is_available)
      refute Enum.any?(weekend_rows, & &1.is_available)

      # Verification email job is enqueued — users must verify before accessing the app.
      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_email_verification", "user_id" => user.id}
      )

      # The registration hook receives the sign-up's metadata.
      assert [hook_job] = all_enqueued(worker: UserRegisteredHookWorker)
      assert hook_job.args["user_id"] == user.id

      assert hook_job.args["metadata"] == %{
               "source" => "signup",
               "ip" => "203.0.113.41",
               "user_agent" => "Composition/1.0",
               "terms_accepted" => true
             }

      # The PubSub event, delivered to every subscriber in the node, names
      # the account and its provider and carries nothing else: no password
      # hash, email or request data.
      user_id = user.id
      assert_received {:user_registered, payload}
      assert payload == %{user_id: user_id, provider: user.provider}
    end
  end

  describe "register_user/2 — provisioning" do
    test "broadcasts no terms acceptance, so the caller decides the legal state" do
      email = "provisioned-#{System.unique_integer([:positive])}@example.com"

      assert {:ok, user, _message} =
               Registration.register_user(
                 %{
                   "email" => email,
                   "password" => "ValidPassword123!",
                   "terms_accepted" => "true"
                 },
                 ip: "203.0.113.42",
                 via: :provisioning
               )

      assert [hook_job] = all_enqueued(worker: UserRegisteredHookWorker)
      assert hook_job.args["user_id"] == user.id
      assert hook_job.args["metadata"] == %{"source" => "provisioning"}
    end
  end

  describe "register_user/2 — rate limit refuses creation" do
    test "does not create a user when the signup rate limit is already exhausted" do
      email = "rate-#{System.unique_integer([:positive])}@example.com"
      opts = ClientIP.request_opts(%Plug.Conn{})

      # Burn through the requester's 10-minute / 5-attempt signup bucket.
      for _i <- 1..5 do
        RateLimiter.check(:signup_ip, opts[:ip])
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
               Registration.register_user(params, opts)

      # No user row was created despite the matching password and terms.
      refute Repo.get_by(UserSchema, email: email)
      refute_received {:user_registered, _payload}
    end
  end
end
