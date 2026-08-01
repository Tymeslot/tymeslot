defmodule TymeslotWeb.AuthLiveSignupRateLimitTest do
  @moduledoc """
  Confirms a genuine signup submission through `AuthLive` consumes exactly
  one signup rate-limit token.

  `SignupSecurity.gate/2` and `Registration.register_user/3` both call
  `Tymeslot.Security.RateLimiter.check_signup_rate_limit/2`, which is a
  counting Hammer hit rather than a read-only peek. If both layers ever
  charged the same LiveView submission, the effective budget would be
  halved and legitimate signups from a shared IP would be locked out
  early.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :auth

  alias Tymeslot.Auth
  alias Tymeslot.Security.RateLimiter

  setup do
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  test "the 6th of 5 allowed distinct signups from one IP is the first rejection", %{conn: conn} do
    # @signup_limits' tightest window allows 5 signups per 10 minutes per
    # IP. Distinct emails from the same connection all draw on the shared
    # per-IP bucket, so 5 successful signups should exhaust it and the 6th
    # must be the first rejection.
    for i <- 1..5 do
      {:ok, view, _html} = live(conn, ~p"/auth/signup")
      email = "rl-signup-#{i}-#{System.unique_integer([:positive])}@example.com"

      result =
        view
        |> form("#signup-form", %{
          "user" => %{
            "email" => email,
            "password" => "ValidPassword123!",
            "website" => ""
          }
        })
        |> render_submit()

      assert result =~ "Account created successfully"
      assert Auth.get_user_by_email(email)
    end

    {:ok, view, _html} = live(conn, ~p"/auth/signup")
    email = "rl-signup-6-#{System.unique_integer([:positive])}@example.com"

    result =
      view
      |> form("#signup-form", %{
        "user" => %{
          "email" => email,
          "password" => "ValidPassword123!",
          "website" => ""
        }
      })
      |> render_submit()

    assert result =~ "Too many signup attempts"
    refute Auth.get_user_by_email(email)
  end
end
