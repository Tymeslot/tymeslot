defmodule Tymeslot.Security.RateLimiterCompositionTest do
  @moduledoc """
  Composition coverage for `Tymeslot.Security.RateLimiter`.

  The per-bucket unit suites already exist:

    * `rate_limiter_auth_test.exs` — login bucket, case/whitespace
      normalisation, AccountLockout integration.
    * `rate_limiter_multi_window_test.exs` — signup / verification /
      password-reset multi-window buckets.
    * `rate_limiter_dashboard_test.exs` et al. — dashboard buckets.

  This file covers the composition pieces that no single unit test
  exercises:

    * the booking-submission, webhook, cancel, and keep buckets that
      only reach RateLimiter through LiveView integration tests,
    * cross-bucket isolation — exhausting one bucket must never bleed
      into another, because the limiter is organised by bucket key,
    * the window-expiry round trip via `clear_bucket/1`, which is the
      only deterministic way to assert "after the window, requests are
      allowed again" without waiting 10+ minutes.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :integration

  alias Tymeslot.Security.RateLimiter

  describe "booking buckets" do
    test "check_booking_submission_limit/1 allows 10 per 20 minutes then denies" do
      ip = unique_ip("booking-ip")

      for _i <- 1..10 do
        assert {:allow, _count} = RateLimiter.check_booking_submission_limit(ip)
      end

      assert {:deny, _retry} = RateLimiter.check_booking_submission_limit(ip)
    end

    test "check_webhook_rate_limit/1 allows 100 per 10 minutes then denies" do
      ip = unique_ip("webhook-ip")

      for _i <- 1..100 do
        assert :ok = RateLimiter.check_webhook_rate_limit(ip)
      end

      assert {:error, :rate_limited} = RateLimiter.check_webhook_rate_limit(ip)
    end

    test "check_meeting_cancel_rate_limit/1 allows 10 per 10 minutes then denies with a message" do
      ip = unique_ip("cancel-ip")

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_meeting_cancel_rate_limit(ip)
      end

      assert {:error, :rate_limited, message} = RateLimiter.check_meeting_cancel_rate_limit(ip)
      assert message =~ "meeting cancellation"
    end

    test "check_meeting_keep_rate_limit/1 allows 10 per 10 minutes then denies with a message" do
      ip = unique_ip("keep-ip")

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_meeting_keep_rate_limit(ip)
      end

      assert {:error, :rate_limited, message} = RateLimiter.check_meeting_keep_rate_limit(ip)
      assert message =~ "meeting keep"
    end
  end

  describe "cross-bucket isolation" do
    test "exhausting the booking bucket does not affect the webhook bucket" do
      ip = unique_ip("cross-booking-webhook")

      for _i <- 1..10, do: RateLimiter.check_booking_submission_limit(ip)
      assert {:deny, _retry} = RateLimiter.check_booking_submission_limit(ip)

      # Webhook bucket shares the IP but has its own key namespace.
      assert :ok = RateLimiter.check_webhook_rate_limit(ip)
    end

    test "exhausting auth for one email does not block signup for another" do
      email_a = unique_email("auth-victim")
      email_b = unique_email("signup-innocent")
      ip_a = unique_ip("auth-ip")
      ip_b = unique_ip("signup-ip")

      # Burn through the login bucket for email_a.
      for _i <- 1..10, do: RateLimiter.check_auth_rate_limit(email_a, ip_a)
      assert {:error, :rate_limited, _msg} = RateLimiter.check_auth_rate_limit(email_a, ip_a)

      # A fresh email signing up from a different IP is unaffected.
      assert :ok = RateLimiter.check_signup_rate_limit(email_b, ip_b)
    end

    test "exhausting password-reset for one IP does not block OAuth initiation from the same IP" do
      email = unique_email("reset-victim")
      ip = unique_ip("shared-ip")

      # Burn through the short password-reset window (5/hour).
      for _i <- 1..5, do: RateLimiter.check_password_reset_rate_limit(email, ip)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_password_reset_rate_limit(email, ip)

      # OAuth initiation has its own bucket and is still allowed.
      assert :ok = RateLimiter.check_oauth_initiation_rate_limit(ip)
    end
  end

  describe "bucket lifecycle via clear_bucket/1" do
    test "clearing the underlying bucket key re-allows requests" do
      ip = unique_ip("clear-cancel")

      for _i <- 1..10, do: RateLimiter.check_meeting_cancel_rate_limit(ip)
      assert {:error, :rate_limited, _msg} = RateLimiter.check_meeting_cancel_rate_limit(ip)

      # clear_bucket/1 is the test-only escape hatch — in production the
      # bucket expires naturally as the sliding window advances. Clearing
      # here simulates the post-window state without waiting 10 minutes.
      :ok = RateLimiter.clear_bucket("meeting_cancel:#{ip}")

      assert :ok = RateLimiter.check_meeting_cancel_rate_limit(ip)
    end

    test "clear_all/0 resets every bucket in one call" do
      ip_cancel = unique_ip("global-clear-cancel")
      ip_keep = unique_ip("global-clear-keep")

      for _i <- 1..10, do: RateLimiter.check_meeting_cancel_rate_limit(ip_cancel)
      for _i <- 1..10, do: RateLimiter.check_meeting_keep_rate_limit(ip_keep)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_meeting_cancel_rate_limit(ip_cancel)

      assert {:error, :rate_limited, _msg} = RateLimiter.check_meeting_keep_rate_limit(ip_keep)

      :ok = RateLimiter.clear_all()

      assert :ok = RateLimiter.check_meeting_cancel_rate_limit(ip_cancel)
      assert :ok = RateLimiter.check_meeting_keep_rate_limit(ip_keep)
    end
  end

  # --- Helpers ---

  defp unique_ip(label), do: "#{label}-#{System.unique_integer([:positive])}"

  defp unique_email(label),
    do: "#{label}-#{System.unique_integer([:positive])}@example.com"
end
