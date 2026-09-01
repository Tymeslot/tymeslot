defmodule TymeslotWeb.AuthLive.RateLimitingTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :auth

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture

  import Tymeslot.Factory

  describe "rate limiting — password reset" do
    setup do
      on_exit(fn -> RateLimiter.clear_all() end)
      :ok
    end

    test "submit_reset_request is blocked after exhausting the per-email rate limit", %{
      conn: conn
    } do
      email = "rl-reset-#{System.unique_integer([:positive])}@example.com"

      # Exhaust the 1-hour per-email bucket (limit: 5)
      for _i <- 1..5 do
        RateLimiter.check_password_reset_rate_limit(email, "test-rate-limit-ip")
      end

      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      result =
        view
        |> form("#reset-password-form", %{"email" => email})
        |> render_submit()

      assert result =~ "Too many"
    end

    test "submit_reset_request spends one attempt, not two", %{conn: conn} do
      email = "rl-reset-once-#{System.unique_integer([:positive])}@example.com"

      # Spend 4 of the 5 hourly attempts against the per-EMAIL bucket, leaving
      # exactly one. The request below must fit in it: the limit is charged in
      # Auth.PasswordReset alone, so a second charge at the LiveView layer
      # would reject a request still inside the budget, and reject it where
      # nothing audits the rejection.
      #
      # The ip argument here is irrelevant to this test: it only feeds the
      # separate per-IP bucket, which the request below never consults (a
      # LiveViewTest connection presents its own default client IP, not this
      # literal). Priming loops that need the per-IP bucket use a shared,
      # deliberately-controlled IP instead — see the per-IP test below.
      for _i <- 1..4 do
        RateLimiter.check_password_reset_rate_limit(email, "ip-irrelevant-to-this-test")
      end

      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      result =
        view
        |> form("#reset-password-form", %{"email" => email})
        |> render_submit()

      refute result =~ "Too many"
      assert result =~ "password reset instructions have been sent"
    end

    test "submit_reset_request audits a rejection via SecurityLogger", %{conn: conn} do
      email = "rl-reset-audit-#{System.unique_integer([:positive])}@example.com"

      # Exhaust the 1-hour per-email bucket (limit: 5) so the request below is
      # rejected by Auth.PasswordReset, which is the only layer left that
      # charges the limit and the only layer that audits a rejection.
      for _i <- 1..5 do
        RateLimiter.check_password_reset_rate_limit(email, "ip-irrelevant-to-this-test")
      end

      result =
        LogCapture.with_capture([logger_level: :info], fn ->
          {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

          view
          |> form("#reset-password-form", %{"email" => email})
          |> render_submit()
        end)

      assert result =~ "Too many"

      assert_receive {:captured_log,
                      %{
                        meta:
                          %{event_type: "rate_limit_violation", limit_type: "password_reset"} =
                            meta
                      }},
                     1_000

      assert meta.ip_address == "127.0.0.1"
    end

    test "submit_reset_request is blocked by the per-IP limit even with fresh emails", %{
      conn: conn
    } do
      ip = "203.0.113.44"

      # Exhaust the 1-hour per-IP bucket (limit: 5) using five DISTINCT emails,
      # so none of their individual per-email buckets goes anywhere near its
      # own limit — only the shared IP bucket accumulates all five charges.
      for _i <- 1..5 do
        prime_email = "rl-reset-ip-prime-#{System.unique_integer([:positive])}@example.com"
        RateLimiter.check_password_reset_rate_limit(prime_email, ip)
      end

      # A brand-new email, never charged before, submitted from the same IP.
      fresh_email = "rl-reset-ip-fresh-#{System.unique_integer([:positive])}@example.com"
      # Make the LiveView connection present the same IP as the priming
      # loop: the default peer is loopback, which is a trusted proxy source,
      # so the forwarded header is honoured (see ClientIP.get_from_mount/1).
      conn = put_req_header(conn, "x-forwarded-for", ip)

      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      result =
        view
        |> form("#reset-password-form", %{"email" => fresh_email})
        |> render_submit()

      assert result =~ "Too many"
    end
  end

  describe "rate limiting — verification resend" do
    setup do
      on_exit(fn -> RateLimiter.clear_all() end)
      :ok
    end

    test "resend_verification is blocked after exhausting the per-user rate limit", %{conn: conn} do
      user = insert(:unverified_user)

      # Exhaust the 1-hour per-user bucket (limit: 5)
      for _i <- 1..5 do
        RateLimiter.check_verification_rate_limit(user.id, "test-rate-limit-ip")
      end

      conn =
        init_test_session(conn, %{
          "unverified_user_id" => user.id,
          "unverified_user_email" => user.email,
          "unverified_session_timestamp" => DateTime.to_unix(DateTime.utc_now())
        })

      {:ok, view, _html} = live(conn, ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      assert render(view) =~ "Too many email verification attempts. Please try again later."
    end

    test "resend_verification disables the button with a live cooldown countdown",
         %{conn: conn} do
      user = insert(:unverified_user)

      conn =
        init_test_session(conn, %{
          "unverified_user_id" => user.id,
          "unverified_user_email" => user.email,
          "unverified_session_timestamp" => DateTime.to_unix(DateTime.utc_now())
        })

      {:ok, view, _html} = live(conn, ~p"/auth/verify-email")

      html = render_hook(view, "resend_verification", %{})

      assert html =~ "Resend available in"
      assert has_element?(view, "button[phx-click='resend_verification'][disabled]")

      # The countdown ticks down via handle_info without re-enabling prematurely.
      send(view.pid, :resend_cooldown_tick)
      assert has_element?(view, "button[phx-click='resend_verification'][disabled]")
    end

    test "the cooldown re-enables the button once it elapses", %{conn: conn} do
      user = insert(:unverified_user)

      conn =
        init_test_session(conn, %{
          "unverified_user_id" => user.id,
          "unverified_user_email" => user.email,
          "unverified_session_timestamp" => DateTime.to_unix(DateTime.utc_now())
        })

      {:ok, view, _html} = live(conn, ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})
      assert has_element?(view, "button[phx-click='resend_verification'][disabled]")

      # Drive the countdown to zero (cooldown starts at @resend_cooldown_seconds = 60).
      for _tick <- 1..60, do: send(view.pid, :resend_cooldown_tick)

      html = render(view)
      refute html =~ "Resend available in"
      assert html =~ "Resend Verification Email"
      refute has_element?(view, "button[phx-click='resend_verification'][disabled]")
    end

    test "a second resend during the cooldown is ignored and does not reset the countdown",
         %{conn: conn} do
      user = insert(:unverified_user)

      conn =
        init_test_session(conn, %{
          "unverified_user_id" => user.id,
          "unverified_user_email" => user.email,
          "unverified_session_timestamp" => DateTime.to_unix(DateTime.utc_now())
        })

      {:ok, view, _html} = live(conn, ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})
      for _tick <- 1..5, do: send(view.pid, :resend_cooldown_tick)
      assert render(view) =~ "Resend available in 55s"

      # A double-click before the disabled patch lands must not restart the cooldown
      # (which would otherwise spawn a second timer chain and drain it early).
      render_hook(view, "resend_verification", %{})
      html = render(view)
      assert html =~ "Resend available in 55s"
      refute html =~ "Resend available in 60s"
    end
  end
end
