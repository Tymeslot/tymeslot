defmodule Tymeslot.Auth.SignupRateLimitTest do
  @moduledoc """
  Confirms a signup consumes exactly one signup rate-limit token per attempt.

  `Registration.register_user/2` runs `SignupSecurity.gate/2`, which performs
  the counting rate-limit check before reCAPTCHA verification, and nothing
  else on the path charges the same attempt a second time.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Auth.{Registration, SignupSecurity}
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture
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
    assert meta.ip_address == "203.0.113.9"
    refute inspect(meta) =~ "gate-plus-register-16@example.com"
  end

  test "buckets a padded/untrimmed email under the same key as its trimmed form" do
    email = "trim-bucket-test@example.com"

    params = fn raw_email ->
      %{
        "email" => raw_email,
        "password" => "ValidPassword123!",
        "password_confirmation" => "ValidPassword123!",
        "terms_accepted" => "true",
        "website" => ""
      }
    end

    # Exhaust the per-email bucket (5 per 10 minutes) with the trimmed form,
    # from a distinct IP each time so only the per-email bucket accumulates.
    for i <- 1..5 do
      conn = ClientIP.request_opts(%Plug.Conn{remote_ip: {203, 0, 113, 100 + i}})
      Registration.register_user(params.(email), conn)
    end

    # A padded variant of the same address, from yet another fresh IP, must
    # still be rejected: if the limiter bucketed on the raw untrimmed value
    # it would get its own fresh bucket and succeed instead.
    conn = ClientIP.request_opts(%Plug.Conn{remote_ip: {203, 0, 113, 200}})

    assert {:error, :rate_limited, _message} =
             Registration.register_user(params.("  " <> email <> "  "), conn)
  end
end
