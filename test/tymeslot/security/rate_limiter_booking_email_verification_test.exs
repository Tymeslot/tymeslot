defmodule Tymeslot.Security.RateLimiterBookingEmailVerificationTest do
  @moduledoc """
  `&RateLimiter.check(:booking_email_verification, &1)/1`, keyed on the client
  IP confirming or disowning a held booking from
  `TymeslotWeb.BookingVerificationLive`.

  Distinct clients must get distinct buckets: were every visitor to resolve to
  one key, the limit meant to slow down somebody working through guessed or
  harvested links would lock out every attendee on the instance instead.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :bookings

  alias Tymeslot.Security.RateLimiter

  describe "check(:booking_email_verification, _)" do
    test "allows 20 attempts per 10 minutes then denies with a message" do
      ip = unique_ip("verification-ip")

      for _i <- 1..20 do
        assert :ok = RateLimiter.check(:booking_email_verification, ip)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check(:booking_email_verification, ip)

      assert message =~ "booking email verification"
    end

    test "one client hitting the limit does not block a different client" do
      exhausted = unique_ip("verification-exhausted")
      fresh = unique_ip("verification-fresh")

      for _i <- 1..20, do: RateLimiter.check(:booking_email_verification, exhausted)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check(:booking_email_verification, exhausted)

      assert :ok = RateLimiter.check(:booking_email_verification, fresh)
    end

    test "clearing the bucket re-allows requests" do
      ip = unique_ip("verification-clear")

      for _i <- 1..20, do: RateLimiter.check(:booking_email_verification, ip)
      assert {:error, :rate_limited, _msg} = RateLimiter.check(:booking_email_verification, ip)

      :ok = RateLimiter.clear_bucket("booking_email_verification:#{ip}")

      assert :ok = RateLimiter.check(:booking_email_verification, ip)
    end
  end

  defp unique_ip(label), do: "#{label}-#{System.unique_integer([:positive])}"
end
