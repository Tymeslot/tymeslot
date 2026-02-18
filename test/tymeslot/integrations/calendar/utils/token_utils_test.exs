defmodule Tymeslot.Integrations.Calendar.TokenUtilsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.TokenUtils

  describe "token_expired?/1" do
    test "returns true for nil" do
      assert TokenUtils.token_expired?(nil)
    end

    test "returns false if token_expires_at is nil" do
      refute TokenUtils.token_expired?(%{token_expires_at: nil})
    end

    test "returns true if token expired" do
      past = DateTime.add(DateTime.utc_now(), -70, :second)
      assert TokenUtils.token_expired?(%{token_expires_at: past})
    end

    test "returns true if token expires within 60 seconds (grace period)" do
      soon = DateTime.add(DateTime.utc_now(), 30, :second)
      assert TokenUtils.token_expired?(%{token_expires_at: soon})
    end

    test "returns false if token is valid for more than 60 seconds" do
      future = DateTime.add(DateTime.utc_now(), 120, :second)
      refute TokenUtils.token_expired?(%{token_expires_at: future})
    end
  end

  describe "format_token_expiry/1" do
    test "handles nil token_expires_at" do
      assert {:no_expiry, "No expiry"} = TokenUtils.format_token_expiry(%{token_expires_at: nil})
    end

    test "handles expired tokens" do
      past = DateTime.add(DateTime.utc_now(), -3700, :second)
      assert {:expired, msg} = TokenUtils.format_token_expiry(%{token_expires_at: past})
      assert msg =~ "1 hour ago"
    end

    test "handles valid tokens" do
      future = DateTime.add(DateTime.utc_now(), 3700, :second)
      assert {:valid, msg} = TokenUtils.format_token_expiry(%{token_expires_at: future})
      assert msg =~ "in 1 hour"
    end

    test "handles unknown input" do
      assert {:unknown, "Unknown"} = TokenUtils.format_token_expiry(%{})
    end
  end

  describe "token_status/1" do
    test "returns correct atoms" do
      assert TokenUtils.token_status(%{token_expires_at: nil}) == :no_expiry

      assert TokenUtils.token_status(%{
               token_expires_at: DateTime.add(DateTime.utc_now(), -3700, :second)
             }) == :expired

      assert TokenUtils.token_status(%{
               token_expires_at: DateTime.add(DateTime.utc_now(), 3700, :second)
             }) == :valid

      assert TokenUtils.token_status(%{}) == :unknown
    end
  end

  describe "relative_time/1" do
    test "formats various time diffs" do
      now = DateTime.utc_now()
      assert TokenUtils.relative_time(DateTime.add(now, 30, :second)) == "just now"
      assert TokenUtils.relative_time(DateTime.add(now, 150, :second)) == "in 2 minutes"
      assert TokenUtils.relative_time(DateTime.add(now, -150, :second)) == "2 minutes ago"
      assert TokenUtils.relative_time(DateTime.add(now, 7500, :second)) == "in 2 hours"
      assert TokenUtils.relative_time(DateTime.add(now, 180_000, :second)) == "in 2 days"
      assert TokenUtils.relative_time(DateTime.add(now, 6_000_000, :second)) == "in 2 months"
    end
  end

  describe "needs_refresh?/2" do
    test "returns true if expiring soon" do
      soon = DateTime.add(DateTime.utc_now(), 120, :second)
      assert TokenUtils.needs_refresh?(%{token_expires_at: soon}, 5)
    end

    test "returns false if expires later" do
      future = DateTime.add(DateTime.utc_now(), 600, :second)
      refute TokenUtils.needs_refresh?(%{token_expires_at: future}, 5)
    end

    test "returns false if no expiry" do
      refute TokenUtils.needs_refresh?(%{token_expires_at: nil}, 5)
    end
  end
end
