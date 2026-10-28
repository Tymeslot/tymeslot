defmodule Tymeslot.Security.RateLimiterConsumeTest do
  @moduledoc """
  Charging several units of a named limit at once, all or none, and the poll
  email limits' configuration.
  """

  # async: false: the buckets are global, and another module's setup clears
  # them all.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :security

  alias Config.Reader
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Limits

  @hour 3_600_000
  @day 86_400_000

  setup do
    RateLimiter.clear_all()
    on_exit(&RateLimiter.clear_all/0)
    :ok
  end

  describe "consume/3" do
    test "charges every tier of the limit once per unit" do
      assert RateLimiter.consume(:poll_host_invitations, 42, 3) == :ok

      assert RateLimit.get("poll_invitations:user:42:1h", @hour) == 3
      assert RateLimit.get("poll_invitations:user:42:1d", @day) == 3
    end

    test "refuses more than the room left, charges nothing, and says how much is left" do
      :ok = RateLimiter.consume(:poll_host_invitations, 42, 99)

      log =
        capture_log(fn ->
          assert RateLimiter.consume(:poll_host_invitations, 42, 2) ==
                   {:error, {:rate_limited, 1}}
        end)

      assert log =~ "Rate limit exceeded"
      assert RateLimit.get("poll_invitations:user:42:1h", @hour) == 99
      assert RateLimiter.consume(:poll_host_invitations, 42, 1) == :ok
    end

    test "keys an address the way check/2 does, whatever its case and spacing" do
      :ok = RateLimiter.consume(:poll_recipient_email, " Ada@Example.COM ", 1)

      assert Enum.sort(RateLimit.keys()) == [
               "poll_recipient:ada@example.com:1d",
               "poll_recipient:ada@example.com:1h"
             ]
    end

    test "refuses a key that is not a user id" do
      capture_log(fn ->
        assert RateLimiter.consume(:poll_host_invitations, nil, 1) ==
                 {:error, :invalid_user_id}
      end)
    end
  end

  describe "remaining/2" do
    test "is the room in the tightest tier, and charges nothing" do
      :ok = RateLimiter.consume(:poll_host_invitations, 42, 40)

      assert RateLimiter.remaining(:poll_host_invitations, 42) == 60
      assert RateLimit.get("poll_invitations:user:42:1h", @hour) == 40
    end
  end

  describe "the poll email limits" do
    test "ship with the documented defaults" do
      config =
        [__DIR__, "..", "..", "..", "config", "config.exs"]
        |> Path.join()
        |> Path.expand()
        |> Reader.read!(env: :dev, target: :host)

      assert config |> get_in([:tymeslot, :poll_email_limits]) |> Enum.sort() ==
               Enum.sort(
                 invitations_per_host_hour: 100,
                 invitations_per_host_day: 300,
                 per_recipient_hour: 3,
                 per_recipient_day: 10,
                 link_requests_per_poll_hour: 30
               )
    end

    test "take a deployment's overrides, key by key" do
      # config/test.exs raises the per-address and per-poll budgets and
      # leaves the host's at the default.
      assert Limits.fetch!(:poll_recipient_email)[:tiers] == [
               {"1h", 1_000, @hour},
               {"1d", 1_000, @day}
             ]

      assert Limits.fetch!(:poll_link_request)[:limit] == 1_000
      assert Limits.fetch!(:poll_link_request)[:window_ms] == @hour

      assert Limits.fetch!(:poll_host_invitations)[:tiers] == [
               {"1h", 100, @hour},
               {"1d", 300, @day}
             ]
    end
  end
end
