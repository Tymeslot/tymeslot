defmodule TymeslotWeb.AuthLive.RateLimitingTest do
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :auth

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.EmailWorker

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

    test "an account at its per-user cap sees the ordinary confirmation and gets no email",
         %{conn: conn} do
      user = insert(:unverified_user)

      # Exhaust the 1-hour per-user bucket (limit: 5)
      for _i <- 1..5 do
        RateLimiter.check_verification_rate_limit(user.id, "test-rate-limit-ip")
      end

      {:ok, view, _html} = live(bind_unverified(conn, user), ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      # The cap is the account's, so saying so would tell whoever is looking that
      # the account exists and is unverified.
      assert render(view) =~ "Verification email sent! Please check your inbox."
      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "the address limit, which says nothing about any account, is shown", %{conn: conn} do
      for _i <- 1..5, do: RateLimiter.check_verification_ip_rate_limit("127.0.0.1")

      user = insert(:unverified_user)
      {:ok, view, _html} = live(bind_unverified(conn, user), ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      assert render(view) =~ "reached the limit of 5 verification emails per hour"
      assert [] = all_enqueued(worker: EmailWorker)
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

  describe "resend verification can't probe or spam an address" do
    setup do
      on_exit(fn -> RateLimiter.clear_all() end)
      :ok
    end

    test "a session-bound unverified account is sent a fresh link", %{conn: conn} do
      user = insert(:unverified_user)
      {:ok, view, _html} = live(bind_unverified(conn, user), ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      assert render(view) =~ "Verification email sent! Please check your inbox."
      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args["user_id"] == user.id
    end

    test "an address typed into the login form is never the resend target", %{conn: conn} do
      victim = insert(:unverified_user)

      {:ok, view, _html} = live(conn, ~p"/auth/login")
      render_hook(view, "validate_login_email", %{"value" => victim.email})
      render_patch(view, ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      # No email to the address; the visitor is asked to sign in instead.
      assert render(view) =~ "Sign in to receive a new verification link."
      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "outside the verify-email screen the event does nothing", %{conn: conn} do
      user = insert(:unverified_user)
      {:ok, view, _html} = live(bind_unverified(conn, user), ~p"/auth/login")

      html = render_hook(view, "resend_verification", %{})

      refute html =~ "Verification email sent"
      refute html =~ "Resend available in"
      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "a session-bound account verified since is sent nothing, and told the same",
         %{conn: conn} do
      user = insert(:user)
      {:ok, view, _html} = live(bind_unverified(conn, user), ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      assert render(view) =~ "Verification email sent! Please check your inbox."
      assert [] = all_enqueued(worker: EmailWorker)
    end

    test "after a sign-up with a taken address the address bucket is still charged", %{
      conn: conn
    } do
      owner = insert(:unverified_user)

      {:ok, view, _html} = live(conn, ~p"/auth/signup")

      view
      |> form("#signup-form", %{
        "user" => %{"email" => owner.email, "password" => "ValidPassword123!", "website" => ""}
      })
      |> render_submit()

      assert_patch(view, ~p"/auth/verify-email")

      # The sign-up spent one of the five, exactly as a new account's
      # verification email would have, so four resends remain.
      for _i <- 1..4 do
        render_hook(view, "resend_verification", %{})
        assert render(view) =~ "Verification email sent! Please check your inbox."
        refute render(view) =~ "reached the limit"
        for _tick <- 1..60, do: send(view.pid, :resend_cooldown_tick)
      end

      render_hook(view, "resend_verification", %{})

      assert render(view) =~ "reached the limit of 5 verification emails per hour"

      assert [] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_email_verification"})
    end

    test "with nothing bound and no sign-up here, it sends the visitor to sign in", %{
      conn: conn
    } do
      # A reload loses the account a sign-up bound, and a direct visit never had
      # one. Nothing about any account is known, so the answer says so plainly
      # rather than claiming an email went out.
      {:ok, view, _html} = live(conn, ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      assert_patch(view, ~p"/auth/login")
      assert render(view) =~ "Sign in to receive a new verification link."
      refute render(view) =~ "Verification email sent"
      assert [] = all_enqueued(worker: EmailWorker)
    end
  end

  defp bind_unverified(conn, user) do
    init_test_session(conn, %{
      "unverified_user_id" => user.id,
      "unverified_user_email" => user.email,
      "unverified_session_timestamp" => DateTime.to_unix(DateTime.utc_now())
    })
  end
end
