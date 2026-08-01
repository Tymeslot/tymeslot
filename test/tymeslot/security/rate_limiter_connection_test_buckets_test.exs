defmodule Tymeslot.Security.RateLimiterConnectionTestBucketsTest do
  @moduledoc """
  Pins the two connection-test buckets with non-default behaviour that no
  other suite exercises directly: `:custom` (the tightest budget, because it
  probes an arbitrary user-supplied host) and `:nextcloud` (its own bucket,
  separate from CalDAV's, even though both are calendar providers).

  Every other bucket already has its own connection-rate-limit suite (see
  `test/tymeslot/integrations/video/mirotalk_connection_rate_limit_test.exs`
  and `test/tymeslot/integrations/calendar/caldav_connection_rate_limit_test.exs`);
  this file covers the two the others leave untouched.
  """

  # Synchronous like the other rate-limiter suites: several tests call
  # `RateLimiter.clear_all/0`, which wipes the shared ETS table these counts
  # depend on.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  alias Tymeslot.Security.RateLimiter

  # The custom video provider's bucket is deliberately tighter than every
  # other connection-test bucket (which default to 20 per 10 minutes): it
  # probes an arbitrary user-supplied host, so it gets 5.
  @custom_limit 5

  # Every other bucket (including :nextcloud) uses the shared default.
  @default_limit 20

  describe ":custom bucket" do
    test "is limited to 5 attempts per actor, not the 20-attempt default" do
      user = insert(:user)

      for _i <- 1..@custom_limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(:custom, {:user, user.id})
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_connection_test_rate_limit(:custom, {:user, user.id})

      assert message =~ "reached the limit"
    end
  end

  describe ":nextcloud bucket" do
    test "is independent of the :caldav bucket for the same user" do
      user = insert(:user)

      for _i <- 1..@default_limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(:nextcloud, {:user, user.id})
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_connection_test_rate_limit(:nextcloud, {:user, user.id})

      # Exhausting :nextcloud must not have drawn from :caldav's own budget.
      assert :ok = RateLimiter.check_connection_test_rate_limit(:caldav, {:user, user.id})
    end
  end
end
