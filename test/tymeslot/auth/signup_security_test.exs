defmodule Tymeslot.Auth.SignupSecurityTest do
  @moduledoc """
  Tests for the signup security gate that decides whether an incoming
  signup submission may proceed to actual user registration.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Auth.SignupSecurity
  alias Tymeslot.Security.RateLimiter

  @meta %{ip: "203.0.113.5", user_agent: "tymeslot-test/1.0"}

  setup do
    RateLimiter.clear_all()
    :ok
  end

  describe "gate/2" do
    test "returns :honeypot when the hidden field is filled" do
      params = %{"email" => "real@example.com", "website" => "http://bot.example"}
      assert :honeypot = SignupSecurity.gate(params, @meta)
    end

    test "treats an empty honeypot as not tripped" do
      params = %{"email" => "real-empty-honeypot@example.com", "website" => ""}
      refute SignupSecurity.gate(params, @meta) == :honeypot
    end

    test "treats a missing honeypot field as not tripped" do
      params = %{"email" => "real@example.com"}
      result = SignupSecurity.gate(params, @meta)
      refute result == :honeypot
    end

    test "treats a non-binary honeypot value as not tripped" do
      params = %{"email" => "real@example.com", "website" => 123}
      result = SignupSecurity.gate(params, @meta)
      refute result == :honeypot
    end
  end

  describe "gate/2 — :ok happy path" do
    test "returns :ok for a well-formed submission when reCAPTCHA is disabled" do
      # test.exs sets signup_enabled: false, so the gate passes after rate-limit check
      params = %{"email" => "happy@example.com", "password" => "ValidPassword123!"}
      assert :ok = SignupSecurity.gate(params, @meta)
    end

    test "different emails do not share rate-limit buckets" do
      params_a = %{"email" => "user-a@example.com"}
      params_b = %{"email" => "user-b@example.com"}

      assert :ok = SignupSecurity.gate(params_a, @meta)
      assert :ok = SignupSecurity.gate(params_b, @meta)
    end
  end

  describe "gate/2 — {:error, :rate_limited, _}" do
    test "returns a rate_limited error after the per-email limit is exhausted" do
      # The signup limit is 5 attempts per 10-minute window; exhaust it.
      email = "rate-me@example.com"
      params = %{"email" => email}

      for _i <- 1..5, do: SignupSecurity.gate(params, @meta)

      assert {:error, :rate_limited, message} = SignupSecurity.gate(params, @meta)
      assert message == "Too many signup attempts. Please try again later."
    end

    test "rate limit error message is a non-empty string" do
      email = "rate-msg@example.com"
      params = %{"email" => email}

      for _i <- 1..5, do: SignupSecurity.gate(params, @meta)

      assert {:error, :rate_limited, message} = SignupSecurity.gate(params, @meta)
      refute message == ""
    end
  end

  describe "gate/2 — {:error, :recaptcha_failed, _}" do
    setup :enable_recaptcha

    test "returns recaptcha_failed when reCAPTCHA is enabled and token is empty" do
      # An empty token is rejected by RecaptchaHelpers.maybe_verify_signup_token/2
      params = %{"email" => "recaptcha-fail@example.com", "g-recaptcha-response" => ""}
      assert {:error, :recaptcha_failed, message} = SignupSecurity.gate(params, @meta)
      assert message == "Security verification failed. Please try again."
    end

    test "returns recaptcha_failed when reCAPTCHA is enabled and token is missing" do
      params = %{"email" => "no-token@example.com"}
      assert {:error, :recaptcha_failed, message} = SignupSecurity.gate(params, @meta)
      assert message == "Security verification failed. Please try again."
    end
  end

  describe "gate/2 — {:error, :recaptcha_script_blocked, _}" do
    setup :enable_recaptcha

    test "returns recaptcha_script_blocked when the client sends the BLOCKED marker" do
      params = %{
        "email" => "blocked@example.com",
        "g-recaptcha-response" => "RECAPTCHA_SCRIPT_BLOCKED"
      }

      assert {:error, :recaptcha_script_blocked, message} = SignupSecurity.gate(params, @meta)
      assert message =~ "Security verification unavailable."
    end

    test "recaptcha_script_blocked message mentions JavaScript" do
      params = %{
        "email" => "blocked-msg@example.com",
        "g-recaptcha-response" => "RECAPTCHA_SCRIPT_BLOCKED"
      }

      assert {:error, :recaptcha_script_blocked, message} = SignupSecurity.gate(params, @meta)
      assert message =~ "JavaScript"
    end
  end

  describe "gate/2 — nil or blank email (regression: I-19)" do
    test "returns a fail-closed error when email is nil — does not crash" do
      params = %{"email" => nil}
      assert {:error, :rate_limited, message} = SignupSecurity.gate(params, @meta)
      assert message == "Too many signup attempts. Please try again later."
    end

    test "returns a fail-closed error when email key is absent — does not crash" do
      params = %{}
      assert {:error, :rate_limited, message} = SignupSecurity.gate(params, @meta)
      assert message == "Too many signup attempts. Please try again later."
    end

    test "returns a fail-closed error when email is an empty string — does not crash" do
      params = %{"email" => ""}
      assert {:error, :rate_limited, message} = SignupSecurity.gate(params, @meta)
      assert message == "Too many signup attempts. Please try again later."
    end

    test "returns a fail-closed error when email is a non-string type — does not crash" do
      params = %{"email" => 12_345}
      assert {:error, :rate_limited, message} = SignupSecurity.gate(params, @meta)
      assert message == "Too many signup attempts. Please try again later."
    end
  end

  describe "log_honeypot_resend/1" do
    test "returns :ok when given full metadata" do
      assert :ok = SignupSecurity.log_honeypot_resend(@meta)
    end

    test "tolerates missing user_agent" do
      assert :ok = SignupSecurity.log_honeypot_resend(%{ip: "127.0.0.1"})
    end
  end

  defp enable_recaptcha(_context) do
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    old_site_key = System.get_env("RECAPTCHA_SITE_KEY")
    old_secret_key = System.get_env("RECAPTCHA_SECRET_KEY")

    Application.put_env(:tymeslot, :recaptcha,
      signup_enabled: true,
      signup_min_score: 0.3,
      signup_action: "signup_form",
      expected_hostnames: []
    )

    System.put_env("RECAPTCHA_SITE_KEY", "test_site_key")
    System.put_env("RECAPTCHA_SECRET_KEY", "test_secret_key")

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, old_cfg)

      if old_site_key,
        do: System.put_env("RECAPTCHA_SITE_KEY", old_site_key),
        else: System.delete_env("RECAPTCHA_SITE_KEY")

      if old_secret_key,
        do: System.put_env("RECAPTCHA_SECRET_KEY", old_secret_key),
        else: System.delete_env("RECAPTCHA_SECRET_KEY")
    end)

    :ok
  end
end
