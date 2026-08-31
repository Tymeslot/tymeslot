defmodule Tymeslot.Auth.RegistrationVerificationRateLimitTest do
  @moduledoc """
  `Verification.verify_user_email/3` may refuse to send, returning the
  three-element `{:error, :rate_limited, message}` that
  `Tymeslot.Infrastructure.VerificationBehaviour` declares alongside the
  two-element form. `Registration` used to `case` over only the two-element
  one, so a refusal raised `CaseClauseError` from inside the LiveView.

  The crash was the visible half. The damage was that it struck after the user
  row was committed but before the profile and the registration broadcast, so
  the address was rejected as a duplicate on retry and the account could never
  be reached. These tests hold both halves: the refusal is returned rather than
  raised, and whatever the outcome the account is left whole.

  The verification module is resolved at runtime via `Application.get_env/3`,
  which is why Dialyzer could not see the missing clause; the limit is
  therefore exhausted for real here rather than mocked.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :security

  alias Tymeslot.Auth.{Registration, UserQueries}
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture

  @client_ip {203, 0, 113, 50}
  @client_ip_string "203.0.113.50"

  # @verification_limits' tightest window allows 5 per hour per IP.
  @verification_hourly_limit 5

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp conn, do: %Plug.Conn{remote_ip: @client_ip}

  defp signup_params(email) do
    %{
      "email" => email,
      "password" => "ValidPassword123!",
      "password_confirmation" => "ValidPassword123!",
      "terms_accepted" => "true"
    }
  end

  # Spends the shared per-IP allowance on other users, leaving the signup under
  # test to be refused on arrival exactly as production's sixth signup was.
  defp exhaust_verification_allowance do
    for n <- 1..@verification_hourly_limit do
      assert :ok =
               RateLimiter.check_verification_rate_limit("earlier-user-#{n}", @client_ip_string)
    end
  end

  test "a refused verification email returns an error instead of raising" do
    exhaust_verification_allowance()

    assert {:error, :rate_limited, message} =
             Registration.register_user(signup_params("refused@example.com"), conn())

    # The tuple shape is the point here: pre-fix this call raised CaseClauseError
    # rather than returning at all. The wording is asserted in the next test.
    assert byte_size(message) > 0
  end

  test "the message tells the user the account exists and to resend" do
    exhaust_verification_allowance()

    assert {:error, :rate_limited, message} =
             Registration.register_user(signup_params("refused-copy@example.com"), conn())

    assert message =~ "account was created"
    assert message =~ "resend"
  end

  test "a refused verification email is recorded as a rate-limit audit entry" do
    exhaust_verification_allowance()

    # SecurityLogger emits at :info; config/test.exs pins the primary level to
    # :warning, so lower it for the duration of the call.
    LogCapture.with_capture([logger_level: :info], fn ->
      assert {:error, :rate_limited, _message} =
               Registration.register_user(signup_params("audited@example.com"), conn())
    end)

    assert_receive {:captured_log, %{meta: %{event_type: "rate_limit_violation"} = meta}}

    assert meta.limit_type == "email_verification"
    assert meta.ip_address == @client_ip_string

    assert {:ok, user} = UserQueries.get_user_by_email("audited@example.com")
    assert meta.user_id == user.id
  end

  test "the account is left complete, not stranded without a profile" do
    exhaust_verification_allowance()

    assert {:error, :rate_limited, _message} =
             Registration.register_user(signup_params("stranded@example.com"), conn())

    assert {:ok, user} = UserQueries.get_user_by_email("stranded@example.com")
    assert Profiles.get_profile(user.id), "the account was committed without a profile"
  end

  test "the registration broadcast still fires so downstream listeners record the signup" do
    # SaaS' LegalAcceptanceListener records the accepted terms off this event;
    # skipping it because an email could not be sent loses that record.
    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, "auth:user_registered")
    exhaust_verification_allowance()

    assert {:error, :rate_limited, _message} =
             Registration.register_user(signup_params("broadcast@example.com"), conn())

    assert_receive {:user_registered, %{user: user}}
    assert user.email == "broadcast@example.com"
  end

  test "a signup within the allowance is unaffected" do
    assert {:ok, user, _message} =
             Registration.register_user(signup_params("allowed@example.com"), conn())

    assert user.email == "allowed@example.com"
    assert Profiles.get_profile(user.id)
  end
end
