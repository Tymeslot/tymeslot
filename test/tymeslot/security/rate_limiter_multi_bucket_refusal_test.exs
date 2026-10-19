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

  alias Tymeslot.Security.RateLimit
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

      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:signup_ip, ip))

      assert {:error, :rate_limited, message} = RateLimiter.check(:signup_ip, ip)

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
               "You've reached the limit of 5 verification emails per hour. " <>
                 "Please try again in 1 hour."
    end

    test "password reset names its hourly tier" do
      ip = "203.0.113.92"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:password_reset_ip, ip))

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:password_reset_ip, ip)

      assert message ==
               "You've reached the limit of 5 password reset requests per hour. " <>
                 "Please try again in 1 hour."
    end

    test "the booking recipient cap names its hourly tier" do
      email = "refusal-recipient@example.com"

      for _i <- 1..5, do: assert(:ok = RateLimiter.check(:booking_recipient, email))

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:booking_recipient, email)

      assert message ==
               "You've reached the limit of 5 bookings per hour. " <>
                 "Please try again in 1 hour."
    end

    # This is also the plural-form test. `@event_move_limits` is the only live
    # tier list with a 60_000 window, so it is the one case that exercises the
    # singular half of the window pair; every other refusal above lands on the
    # plural half.
    test "a calendar event move names its one-minute tier in the singular, not as per 1 minutes" do
      user_id = 99_501

      for _i <- 1..3, do: assert(:ok = RateLimiter.check(:calendar_event_move, user_id))

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:calendar_event_move, user_id)

      assert message ==
               "You've reached the limit of 3 calendar event moves per minute. " <>
                 "Please try again in 1 minute."

      refute message =~ "per 1 minutes"
    end
  end

  describe "locale" do
    test "the refusal arrives in the reader's language, label and all" do
      ip = "203.0.113.93"

      message =
        Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
          for _i <- 1..5, do: assert(:ok = RateLimiter.check(:signup_ip, ip))

          assert {:error, :rate_limited, message} = RateLimiter.check(:signup_ip, ip)
          message
        end)

      assert message ==
               "Sie haben das Limit von 5 Registrierungsversuchen pro 10 Minuten erreicht. " <>
                 "Bitte versuchen Sie es in 10 Minuten erneut."
    end

    test "the log line stays English while the sentence is translated" do
      LogCapture.attach()

      # A tiered limit that logs its own refusals (the auth ones leave that to
      # the auth flows' security event).
      email = "tiers-#{System.unique_integer([:positive])}@example.com"

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        for _i <- 1..5, do: RateLimiter.check(:booking_recipient, email)
        assert {:error, :rate_limited, _message} = RateLimiter.check(:booking_recipient, email)
      end)

      assert_receive {:captured_log, %{level: :warning, meta: %{operation: operation} = meta}}

      # `operation` is what a log search is keyed on, so it must not follow the
      # reader's locale the way the sentence does.
      assert operation == "booking"
      assert meta.limit == 5
      assert meta.window_minutes == 60
    end
  end

  describe "which tier speaks" do
    # The refusal names the tier a retry has to wait longest for, so that the
    # limit, the window and the wait in one sentence agree. This used to be
    # the first tier in list order to refuse, the shortest window, which with
    # a longer tier also full told people to come back in a minute when a
    # retry then would be refused again for a day.
    @same_budget_tiers [{"1m", 3, 60_000}, {"1d", 3, 24 * 60 * 60_000}]

    test "a longer tier that is also full is the one the message names" do
      bucket = fresh_bucket()

      for _i <- 1..3, do: assert(:ok = charge(bucket, @same_budget_tiers))

      assert {:error, :rate_limited, message} = charge(bucket, @same_budget_tiers)

      assert message ==
               "You've reached the limit of 3 widgets per day. " <>
                 "Please try again in 1 day."
    end

    test "the shorter tier speaks when a retry after its wait would pass" do
      # The anchor for the test above: with room left in the day, a minute
      # does do, and sending somebody away for a day is the failure this pins.
      tiers = [{"1m", 3, 60_000}, {"1d", 10, 24 * 60 * 60_000}]
      bucket = fresh_bucket()

      for _i <- 1..3, do: assert(:ok = charge(bucket, tiers))

      assert {:error, :rate_limited, message} = charge(bucket, tiers)

      assert message ==
               "You've reached the limit of 3 widgets per minute. " <>
                 "Please try again in 1 minute."
    end
  end

  describe "the wait" do
    # The walk halts on the minute tier, but a retry walks every tier again:
    # a wait timed by the refusing tier alone would send someone back into
    # the hour tier, which is still full, so that is the tier that speaks.
    test "covers a longer tier that a retry would still trip" do
      bucket = fresh_bucket()
      tiers = [{"1m", 2, 60_000}, {"1h", 3, 60 * 60_000}]

      for _i <- 1..2, do: RateLimit.hit("#{bucket}:1m", 60_000, 2)
      for _i <- 1..3, do: RateLimit.hit("#{bucket}:1h", 60 * 60_000, 3)

      assert {:error, :rate_limited, message} = charge(bucket, tiers)

      assert message ==
               "You've reached the limit of 3 widgets per hour. " <>
                 "Please try again in 1 hour."

      # Working the wait out charged nothing past the refusing tier.
      assert length(RateLimit.entries("#{bucket}:1h")) == 3
    end
  end

  describe "windows wider than an hour" do
    # The signup, verification and password-reset ladders all run to a year,
    # and the walk reaches those tiers whenever the attempts are spread out
    # rather than burst. Rendered in minutes they read "per 1440 minutes" and
    # "per 525600 minutes", which is the copy this pins out of existence.
    test "a day-long tier is named in days, not in minutes" do
      message = refuse_with([{"1d", 1, 24 * 60 * 60_000}])

      assert message ==
               "You've reached the limit of 1 widgets per day. Please try again in 1 day."
    end

    test "a year-long tier is named in days rather than six figures of minutes" do
      message = refuse_with([{"1y", 1, 365 * 24 * 60 * 60_000}])

      assert message ==
               "You've reached the limit of 1 widgets per 365 days. " <>
                 "Please try again in 365 days."
    end

    test "an hours-wide tier is named in hours" do
      message = refuse_with([{"3h", 1, 3 * 60 * 60_000}])

      assert message ==
               "You've reached the limit of 1 widgets per 3 hours. " <>
                 "Please try again in 3 hours."
    end

    # Days are the widest unit: a 30-day window is not a calendar month, and
    # rendering it as one would overstate how long the door stays shut.
    test "a month-long tier stays in days rather than becoming a month" do
      message = refuse_with([{"1mo", 1, 30 * 24 * 60 * 60_000}])

      assert message =~ "per 30 days"
      refute message =~ "month"
    end
  end

  defp refuse_with(tiers) do
    bucket = fresh_bucket()

    assert :ok = charge(bucket, tiers)
    assert {:error, :rate_limited, message} = charge(bucket, tiers)

    message
  end

  defp fresh_bucket, do: "tier_order_test:#{System.unique_integer([:positive])}"

  defp charge(bucket, tiers) do
    Helpers.check_multi_bucket_limits([{bucket, tiers, "tier order test", "widgets"}])
  end
end
