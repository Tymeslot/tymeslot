defmodule TymeslotWeb.AuthLiveSignupHoneypotTest do
  use TymeslotWeb.LiveCase, async: false

  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  @moduledoc """
  Tests for honeypot-based bot detection in signup flow.

  Note: Honeypot detection happens *before* reCAPTCHA verification,
  so these tests validate that bot attempts are caught early without
  requiring Google API calls or valid reCAPTCHA tokens.
  """

  setup do
    ensure_rate_limiter_started()
    RateLimiter.clear_all()
    :ok
  end

  defp honeypot_signup_form(view, website_value) do
    params = %{
      "email" => "honeypot@example.com",
      "password" => "ValidPassword123!",
      "terms_accepted" => "true",
      "website" => website_value
    }

    view
    |> form("#signup-form", %{"user" => params})
    |> render_submit()
  end

  test "honeypot submission with whitespace-only value is dropped", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/signup")

    honeypot_signup_form(view, "   ")

    assert_patch(view, ~p"/auth/verify-email")
    assert Repo.aggregate(UserSchema, :count, :id) == 0
    assert render(view) =~ "Account created successfully"
  end

  test "honeypot submission drops signup but keeps success flow", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/signup")

    honeypot_signup_form(view, "http://bot.example")

    assert_patch(view, ~p"/auth/verify-email")
    assert Repo.aggregate(UserSchema, :count, :id) == 0
    assert render(view) =~ "Account created successfully"

    view
    |> element("button", "Resend Verification Email")
    |> render_click()

    assert Repo.aggregate(UserSchema, :count, :id) == 0
  end

  test "honeypot resend verification is rate limited and logged", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/signup")

    honeypot_signup_form(view, "http://bot.example")

    assert_patch(view, ~p"/auth/verify-email")
    assert Repo.aggregate(UserSchema, :count, :id) == 0

    Enum.each(1..5, fn _ ->
      html =
        view
        |> element("button", "Resend Verification Email")
        |> render_click()

      assert html =~ "Verification email sent! Please check your inbox."
    end)

    html =
      view
      |> element("button", "Resend Verification Email")
      |> render_click()

    assert html =~ "Too many email verification attempts. Please try again later."
  end

  defp ensure_rate_limiter_started do
    case Process.whereis(Tymeslot.Security.RateLimiter) do
      nil -> start_supervised!(Tymeslot.Security.RateLimiter)
      _pid -> :ok
    end
  end
end
