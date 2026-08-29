defmodule Tymeslot.Security.RateLimiterMeetingApprovalTest do
  @moduledoc """
  `RateLimiter.check_meeting_approval_rate_limit/1`, keyed on the client IP
  answering a booking request from `TymeslotWeb.MeetingRequestLive`.

  This bucket previously had no coverage at all — the LiveView called it, but
  nothing asserted the limit actually bites, or that distinct clients get
  distinct buckets. That gap is exactly how the route shipped without
  `TymeslotWeb.Hooks.ClientInfoHook`: every visitor resolved to the same
  `"unknown"` key, so the limit — meant to slow down someone working through
  guessed or harvested links — instead locked out every host on the instance
  after twenty answers from anybody.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :bookings

  alias Tymeslot.Security.RateLimiter

  describe "check_meeting_approval_rate_limit/1" do
    test "allows 20 answers per 10 minutes then denies with a message" do
      ip = unique_ip("approval-ip")

      for _i <- 1..20 do
        assert :ok = RateLimiter.check_meeting_approval_rate_limit(ip)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_meeting_approval_rate_limit(ip)

      assert message =~ "booking request answer"
    end

    test "one client hitting the limit does not block a different client" do
      exhausted = unique_ip("approval-exhausted")
      fresh = unique_ip("approval-fresh")

      for _i <- 1..20, do: RateLimiter.check_meeting_approval_rate_limit(exhausted)

      assert {:error, :rate_limited, _msg} =
               RateLimiter.check_meeting_approval_rate_limit(exhausted)

      # A regression to the "unknown" bucket collapse (every client sharing
      # one key) would make this deny too.
      assert :ok = RateLimiter.check_meeting_approval_rate_limit(fresh)
    end

    test "clearing the bucket re-allows requests" do
      ip = unique_ip("approval-clear")

      for _i <- 1..20, do: RateLimiter.check_meeting_approval_rate_limit(ip)
      assert {:error, :rate_limited, _msg} = RateLimiter.check_meeting_approval_rate_limit(ip)

      :ok = RateLimiter.clear_bucket("meeting_approval:#{ip}")

      assert :ok = RateLimiter.check_meeting_approval_rate_limit(ip)
    end
  end

  defp unique_ip(label), do: "#{label}-#{System.unique_integer([:positive])}"
end
