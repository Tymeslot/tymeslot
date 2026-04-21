defmodule Tymeslot.Security.RateLimiterOAuthTest do
  @moduledoc """
  Direct coverage for the four OAuth rate-limit buckets exposed by
  `Tymeslot.Security.RateLimiter`:

    * initiation  — 10 per 10 minutes per IP
    * callback    — 20 per 2 minutes per IP
    * completion  —  6 per 20 minutes per IP
    * registration —  6 per 20 minutes per IP

  Each bucket is keyed separately so exhausting one does not trip another.
  This is not the composition test for the OAuth flow itself — that is in
  `flow_handler_composition_test.exs`. The goal here is to pin the limits
  and bucket isolation so a bucket-wiring regression (e.g. two buckets
  accidentally sharing a key) fails loudly.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    on_exit(fn -> RateLimiter.clear_all() end)
    :ok
  end

  describe "initiation bucket (10 per 10 minutes)" do
    test "allows 10 attempts then rate-limits the 11th" do
      ip = unique_ip()

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_oauth_initiation_rate_limit(ip)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_oauth_initiation_rate_limit(ip)

      assert message =~ "OAuth initiation"
    end
  end

  describe "callback bucket (20 per 2 minutes)" do
    test "allows 20 attempts then rate-limits the 21st" do
      ip = unique_ip()

      for _i <- 1..20 do
        assert :ok = RateLimiter.check_oauth_callback_rate_limit(ip)
      end

      assert {:error, :rate_limited, message} = RateLimiter.check_oauth_callback_rate_limit(ip)
      assert message =~ "OAuth callback"
    end
  end

  describe "completion bucket (6 per 20 minutes)" do
    test "allows 6 attempts then rate-limits the 7th" do
      ip = unique_ip()

      for _i <- 1..6 do
        assert :ok = RateLimiter.check_oauth_completion_rate_limit(ip)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_oauth_completion_rate_limit(ip)

      assert message =~ "OAuth completion"
    end
  end

  describe "registration bucket (6 per 20 minutes)" do
    test "allows 6 attempts then rate-limits the 7th" do
      ip = unique_ip()

      for _i <- 1..6 do
        assert :ok = RateLimiter.check_oauth_registration_rate_limit(ip)
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_oauth_registration_rate_limit(ip)

      assert message =~ "OAuth registration"
    end
  end

  describe "bucket isolation" do
    test "exhausting initiation does not impact callback, completion, or registration" do
      ip = unique_ip()

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_oauth_initiation_rate_limit(ip)
      end

      assert {:error, :rate_limited, _msg} = RateLimiter.check_oauth_initiation_rate_limit(ip)

      # Every other bucket still has its full budget for this IP.
      assert :ok = RateLimiter.check_oauth_callback_rate_limit(ip)
      assert :ok = RateLimiter.check_oauth_completion_rate_limit(ip)
      assert :ok = RateLimiter.check_oauth_registration_rate_limit(ip)
    end

    test "exhausting registration does not impact initiation, callback, or completion" do
      ip = unique_ip()

      for _i <- 1..6 do
        assert :ok = RateLimiter.check_oauth_registration_rate_limit(ip)
      end

      assert {:error, :rate_limited, _msg} = RateLimiter.check_oauth_registration_rate_limit(ip)

      assert :ok = RateLimiter.check_oauth_initiation_rate_limit(ip)
      assert :ok = RateLimiter.check_oauth_callback_rate_limit(ip)
      assert :ok = RateLimiter.check_oauth_completion_rate_limit(ip)
    end

    test "two different IPs on the same bucket have independent budgets" do
      ip_a = unique_ip()
      ip_b = unique_ip()

      for _i <- 1..10 do
        assert :ok = RateLimiter.check_oauth_initiation_rate_limit(ip_a)
      end

      assert {:error, :rate_limited, _msg} = RateLimiter.check_oauth_initiation_rate_limit(ip_a)
      # ip_b is untouched.
      assert :ok = RateLimiter.check_oauth_initiation_rate_limit(ip_b)
    end
  end

  defp unique_ip, do: "oauth-ip-#{System.unique_integer([:positive])}"
end
