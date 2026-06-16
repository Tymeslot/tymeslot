defmodule TymeslotWeb.AuthLiveSignupHoneypotTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  @moduledoc """
  Tests for honeypot-based bot detection in signup flow.

  Note: Honeypot detection happens *before* reCAPTCHA verification,
  so these tests validate that bot attempts are caught early without
  requiring Google API calls or valid reCAPTCHA tokens.
  """

  setup do
    RateLimiter.clear_all()

    # Ensure legal agreements are enforced for consistent form structure in tests
    original_enforce = Application.get_env(:tymeslot, :enforce_legal_agreements)
    Application.put_env(:tymeslot, :enforce_legal_agreements, true)

    on_exit(fn ->
      Application.put_env(:tymeslot, :enforce_legal_agreements, original_enforce)
    end)

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
    {:ok, view, _initial_html} = live(conn, ~p"/auth/signup")

    honeypot_signup_form(view, "   ")

    assert_patch(view, ~p"/auth/verify-email")
    assert Repo.aggregate(UserSchema, :count, :id) == 0
    assert render(view) =~ "Account created successfully"
  end

  test "honeypot submission drops signup but keeps success flow", %{conn: conn} do
    {:ok, view, _initial_html} = live(conn, ~p"/auth/signup")

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
    {:ok, view, _initial_html} = live(conn, ~p"/auth/signup")

    honeypot_signup_form(view, "http://bot.example")

    assert_patch(view, ~p"/auth/verify-email")
    assert Repo.aggregate(UserSchema, :count, :id) == 0

    Enum.each(1..5, fn _iteration ->
      # The button enters a 60s cooldown after each resend and a click during the
      # cooldown is ignored server-side, so trigger the event directly and drive the
      # countdown back to zero before the next attempt reaches the rate limiter.
      html = render_hook(view, "resend_verification", %{})
      assert html =~ "Verification email sent! Please check your inbox."

      for _tick <- 1..60, do: send(view.pid, :resend_cooldown_tick)
    end)

    html = render_hook(view, "resend_verification", %{})

    assert html =~ "Too many email verification attempts. Please try again later."
  end
end
