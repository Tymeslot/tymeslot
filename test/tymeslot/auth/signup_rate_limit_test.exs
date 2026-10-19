defmodule Tymeslot.Auth.SignupRateLimitTest do
  @moduledoc """
  Confirms a signup consumes exactly one signup rate-limit token per attempt.

  `Registration.register_user/2` runs `SignupSecurity.gate/2`, which performs
  the counting rate-limit check before reCAPTCHA verification, and nothing
  else on the path charges the same attempt a second time.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Auth.{Registration, SignupSecurity, UserSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Helpers.ClientIP

  @opts [ip: "203.0.113.9", user_agent: "signup-rate-limit-test/1.0"]

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp signup_params(index) do
    %{
      "email" => "gate-plus-register-#{index}@example.com",
      "password" => "ValidPassword123!",
      "password_confirmation" => "ValidPassword123!",
      "terms_accepted" => "true",
      "website" => ""
    }
  end

  test "register_user/2 counts one hit per attempt" do
    # @signup_limits' tightest window allows 5 signups per 10 minutes per IP.
    # Five registrations for distinct emails from the same IP must consume
    # exactly 5 tokens, not 10.
    for i <- 1..5 do
      assert {:ok, _user, _message} = Registration.register_user(signup_params(i), @opts)
    end

    # A 6th attempt on the same IP is the first rejection. Had anything on the
    # path charged a second hit per attempt, the bucket would already have
    # tripped after the 3rd.
    assert {:error, :rate_limited, _message} = SignupSecurity.gate(signup_params(6), @opts)
  end

  test "register_user/2 records an audit entry when it rejects on its own rate limit" do
    conn = ClientIP.request_opts(%Plug.Conn{remote_ip: {203, 0, 113, 9}})

    for i <- 11..15 do
      assert {:ok, _user, _message} = Registration.register_user(signup_params(i), conn)
    end

    # SecurityLogger emits at :info; config/test.exs pins the primary level to
    # :warning, so lower it for the duration of the call.
    LogCapture.with_capture([logger_level: :info], fn ->
      assert {:error, :rate_limited, _message} =
               Registration.register_user(signup_params(16), conn)
    end)

    assert_receive {:captured_log, %{meta: %{event_type: "rate_limit_violation"} = meta}}

    assert meta.limit_type == "signup"
    assert meta.email_masked == "g***@example.com"
    # Logged as its network: the redactor truncates every client IP.
    assert meta.ip_address == "203.0.113.0/24"
    refute inspect(meta) =~ "gate-plus-register-16@example.com"
  end

  test "buckets a padded/untrimmed email under the same key as its trimmed form" do
    email = "trim-bucket-test@example.com"

    # Exhaust the per-address budget (5 per 10 minutes) with the trimmed form.
    for _i <- 1..5, do: assert(:ok = RateLimiter.check(:signup_email, email))

    # A padded variant of the same address must still be over the allowance:
    # bucketed on the raw untrimmed value it would get a fresh budget, and an
    # account would be created.
    conn = ClientIP.request_opts(%Plug.Conn{remote_ip: {203, 0, 113, 200}})

    assert {:existing_account, _message} =
             Registration.register_user(signup_params_for("  " <> email <> "  "), conn)

    refute Repo.get_by(UserSchema, email: email)
  end

  describe "an address over its own sign-up allowance" do
    # The per-address budget can be spent by anyone who types the address, so
    # a refusal on it must not reach the visitor: one client could otherwise
    # keep the owner from signing up for a day.
    @victim_ip ClientIP.request_opts(%Plug.Conn{remote_ip: {198, 51, 100, 20}})

    setup do
      victim = "capped-#{System.unique_integer([:positive])}@example.com"

      # Spent from another client, as an attacker would spend it.
      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:signup_email, victim))

      %{victim: victim}
    end

    test "gets a new account's reply, and no account and no email", %{victim: victim} do
      assert {:ok, _user, fresh_reply} =
               Registration.register_user(signup_params_for(unique_email()), @victim_ip)

      Repo.delete_all(Oban.Job)

      assert {:existing_account, reply} =
               Registration.register_user(signup_params_for(victim), @victim_ip)

      assert reply == fresh_reply
      refute Repo.get_by(UserSchema, email: victim)
      assert all_enqueued(worker: EmailWorker) == []
    end

    test "is audited as a signup rate-limit violation", %{victim: victim} do
      LogCapture.with_capture([logger_level: :info], fn ->
        assert {:existing_account, _reply} =
                 Registration.register_user(signup_params_for(victim), @victim_ip)
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "rate_limit_violation"} = meta}}

      assert meta.limit_type == "signup"
      assert meta.email_masked == "c***@example.com"
      assert meta.ip_address == "198.51.100.0/24"
    end

    test "still answers invalid input with its validation errors", %{victim: victim} do
      params = %{signup_params_for(victim) | "password" => "short"}

      assert {:error, :input, errors} = Registration.register_user(params, @victim_ip)
      assert Map.has_key?(errors, :password)
    end

    test "is refused out loud to a provisioning caller", %{victim: victim} do
      assert {:error, :rate_limited, message} =
               Registration.register_user(
                 signup_params_for(victim),
                 Keyword.put(@victim_ip, :via, :provisioning)
               )

      assert message =~ "signup attempts"
      refute Repo.get_by(UserSchema, email: victim)
    end
  end

  test "a client over its own limit is refused out loud and spends nothing of the address's" do
    victim = unique_email()
    attacker = ClientIP.request_opts(%Plug.Conn{remote_ip: {198, 51, 100, 30}})

    for _i <- 1..5 do
      assert {:ok, _user, _message} =
               Registration.register_user(signup_params_for(unique_email()), attacker)
    end

    for _i <- 1..10 do
      assert {:error, :rate_limited, _message} =
               Registration.register_user(signup_params_for(victim), attacker)
    end

    owner = ClientIP.request_opts(%Plug.Conn{remote_ip: {198, 51, 100, 31}})

    assert {:ok, %UserSchema{email: ^victim}, _message} =
             Registration.register_user(signup_params_for(victim), owner)
  end

  defp signup_params_for(email), do: %{signup_params(0) | "email" => email}

  defp unique_email, do: "signup-#{System.unique_integer([:positive])}@example.com"
end
