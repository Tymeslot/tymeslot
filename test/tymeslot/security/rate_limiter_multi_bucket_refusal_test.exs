defmodule Tymeslot.Security.RateLimiterMultiBucketRefusalTest do
  @moduledoc """
  What a tiered bucket *says* when it refuses.

  `Tymeslot.Security.RateLimiterMultiWindowTest` pins that the tiers hold;
  this file pins the sentence the person reads: which limit stopped them, over
  what window, how long the wait is, and that all of it arrives in their own
  language rather than in English.
  """

  # Synchronous like the other rate-limiter suites: `clear_all/0` wipes the
  # shared ETS table every bucket count lives in, and the log assertion below
  # attaches a global `:logger` handler.
  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :i18n

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Helpers
  alias Tymeslot.Test.LogCapture

  setup do
    RateLimiter.clear_all()
    :ok
  end

  describe "the five refusals this path produces" do
    test "signup names its 10-minute tier" do
      ip = "203.0.113.90"
      email = "refusal-signup@example.com"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check_signup_rate_limit(email, ip))

      assert {:error, :rate_limited, message} = RateLimiter.check_signup_rate_limit(email, ip)

      assert message ==
               "You've reached the limit of 5 signup attempts per 10 minutes. " <>
                 "Please try again in 10 minutes."
    end

    test "verification resend names its hourly tier" do
      user_id = "refusal-verification-user"
      ip = "203.0.113.91"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check_verification_rate_limit(user_id, ip))

      assert {:error, :rate_limited, message} =
               RateLimiter.check_verification_rate_limit(user_id, ip)

      assert message ==
               "You've reached the limit of 5 verification emails per 60 minutes. " <>
                 "Please try again in 60 minutes."
    end

    test "password reset names its hourly tier" do
      email = "refusal-reset@example.com"
      ip = "203.0.113.92"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check_password_reset_rate_limit(email, ip))

      assert {:error, :rate_limited, message} =
               RateLimiter.check_password_reset_rate_limit(email, ip)

      assert message ==
               "You've reached the limit of 5 password reset requests per 60 minutes. " <>
                 "Please try again in 60 minutes."
    end

    test "the booking recipient cap names its hourly tier" do
      email = "refusal-recipient@example.com"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check_booking_recipient_limit(email))

      assert {:error, :rate_limited, message} =
               RateLimiter.check_booking_recipient_limit(email)

      assert message ==
               "You've reached the limit of 5 bookings per 60 minutes. " <>
                 "Please try again in 60 minutes."
    end

    # This is also the plural-form test. `@event_move_limits` is the only live
    # tier list with a 60_000 window, so it is the one case that exercises the
    # singular half of the window pair; every other refusal above lands on the
    # plural half.
    test "a calendar event move names its one-minute tier in the singular, not as per 1 minutes" do
      user_id = 99_501

      for _i <- 1..3, do: assert(:ok = RateLimiter.check_calendar_event_move_rate_limit(user_id))

      assert {:error, :rate_limited, message} =
               RateLimiter.check_calendar_event_move_rate_limit(user_id)

      assert message ==
               "You've reached the limit of 3 calendar event moves per minute. " <>
                 "Please try again in 1 minute."

      refute message =~ "per 1 minutes"
    end
  end

  describe "locale" do
    test "the refusal arrives in the reader's language, label and all" do
      ip = "203.0.113.93"
      email = "refusal-locale@example.com"

      message =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          for _i <- 1..5, do: assert(:ok = RateLimiter.check_signup_rate_limit(email, ip))

          assert {:error, :rate_limited, message} = RateLimiter.check_signup_rate_limit(email, ip)
          message
        end)

      assert message ==
               "Sie haben das Limit von 5 Registrierungsversuchen pro 10 Minuten erreicht. " <>
                 "Bitte versuchen Sie es in 10 Minuten erneut."
    end

    test "the log line stays English while the sentence is translated" do
      LogCapture.attach()

      ip = "203.0.113.94"
      email = "refusal-log@example.com"

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        for _i <- 1..5, do: RateLimiter.check_signup_rate_limit(email, ip)
        assert {:error, :rate_limited, _message} = RateLimiter.check_signup_rate_limit(email, ip)
      end)

      assert_receive {:captured_log, %{level: :warning, meta: %{operation: operation} = meta}}

      # `operation` is what a log search is keyed on, so it must not follow the
      # reader's locale the way the sentence does.
      assert operation == "signup"
      assert meta.limit == 5
      assert meta.window_minutes == 10
    end
  end

  describe "tier order" do
    # Both tiers carry the same budget, so after three charges either one would
    # refuse. The walk is ordered shortest window first and halts on the first
    # refusal, so the minute-long tier is the one that must speak: sending
    # somebody away for a day when a minute would do is the failure this pins.
    @same_budget_tiers [{"1m", 3, 60_000}, {"1d", 3, 24 * 60 * 60_000}]

    test "the tightest tier that tripped is the one the message names" do
      bucket = fresh_bucket()

      for _i <- 1..3, do: assert(:ok = charge(bucket, @same_budget_tiers))

      assert {:error, :rate_limited, message} = charge(bucket, @same_budget_tiers)

      assert message =~ "per minute"
      refute message =~ "per 1440 minutes"
    end

    test "list order, not window length, is what decides that" do
      # The anchor for the test above: the same two tiers the other way round
      # refuse on the day-long one, so the assertion there can genuinely fail.
      reversed = Enum.reverse(@same_budget_tiers)
      bucket = fresh_bucket()

      for _i <- 1..3, do: assert(:ok = charge(bucket, reversed))

      assert {:error, :rate_limited, message} = charge(bucket, reversed)

      assert message =~ "per 1440 minutes"
    end
  end

  defp fresh_bucket, do: "tier_order_test:#{System.unique_integer([:positive])}"

  defp charge(bucket, tiers) do
    Helpers.check_multi_bucket_limits([{bucket, tiers, "tier order test", "widgets"}])
  end
end
