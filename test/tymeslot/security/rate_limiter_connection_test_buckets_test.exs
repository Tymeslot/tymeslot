defmodule Tymeslot.Security.RateLimiterConnectionTestBucketsTest do
  @moduledoc """
  Pins the connection-test buckets with non-default behaviour that no other
  suite exercises directly: `:custom`, `:jitsi` and `:ics_url` (the tightest
  budget, because each probes an arbitrary user-supplied host), `:kmeet` (its
  own bucket on the default budget) and `:nextcloud` (its own bucket,
  separate from CalDAV's, even though both are calendar providers).

  Every other bucket already has its own connection-rate-limit suite (see
  `test/tymeslot/integrations/video/mirotalk_connection_rate_limit_test.exs`
  and `test/tymeslot/integrations/calendar/caldav_connection_rate_limit_test.exs`);
  this file covers the ones the others leave untouched.
  """

  # Synchronous like the other rate-limiter suites: several tests call
  # `RateLimiter.clear_all/0`, which wipes the shared ETS table these counts
  # depend on.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  alias Tymeslot.Integrations.Video.Providers.JitsiProvider
  alias Tymeslot.Integrations.Video.Providers.KmeetProvider
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

  describe ":ics_url bucket" do
    test "is limited to 5 attempts per actor, independent of :caldav" do
      user = insert(:user)

      for _i <- 1..@custom_limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(:ics_url, {:user, user.id})
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_connection_test_rate_limit(:ics_url, {:user, user.id})

      assert message =~ "reached the limit"

      # Exhausting :ics_url must not have drawn from :caldav's own budget.
      assert :ok = RateLimiter.check_connection_test_rate_limit(:caldav, {:user, user.id})
    end
  end

  # Both buckets are read off the provider, so these also prove that the
  # bucket each provider declares is one the limiter knows.
  describe ":jitsi bucket" do
    test "is limited to 5 attempts per actor, independent of :custom" do
      user = insert(:user)
      bucket = JitsiProvider.connection_test_bucket()

      for _i <- 1..@custom_limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(bucket, {:user, user.id})
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_connection_test_rate_limit(bucket, {:user, user.id})

      assert message =~ "reached the limit"

      # A Jitsi server is its own host, so it must not share the custom link's budget.
      assert :ok = RateLimiter.check_connection_test_rate_limit(:custom, {:user, user.id})
    end
  end

  describe ":kmeet bucket" do
    test "allows the 20-attempt default, independent of :jitsi" do
      user = insert(:user)
      bucket = KmeetProvider.connection_test_bucket()

      for _i <- 1..@default_limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(bucket, {:user, user.id})
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_connection_test_rate_limit(bucket, {:user, user.id})

      assert :ok = RateLimiter.check_connection_test_rate_limit(:jitsi, {:user, user.id})
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
