defmodule Tymeslot.Integrations.Calendar.OAuthConnectionRateLimitTest do
  @moduledoc """
  Every OAuth-backed provider (Google and Outlook calendar, Zoom, Teams,
  Google Meet) now draws from a real `:oauth` bucket, per actor, instead of
  running unmetered. Without this, a "Test connection" click for one of
  these providers is unbounded and can burn the instance-wide OAuth quota
  shared by every user.

  Google Calendar is the harness here; the bucket itself is provider-agnostic
  (see `Tymeslot.Integrations.Shared.Oauth.OAuthBase.connection_test_bucket/0`
  and the video OAuth providers' own declarations), so pinning it for one
  provider is enough to catch a regression in the shared choke point,
  `Tymeslot.Integrations.Shared.ConnectionProbe`.
  """

  # Synchronous like the other rate-limiter suites: several async tests call
  # `RateLimiter.clear_all/0`, which wipes the shared ETS table these counts
  # depend on.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Connection
  alias Tymeslot.Security.RateLimiter

  # The bucket allows 20 connection tests per 10 minutes per actor.
  @limit 20

  setup :verify_on_exit!

  setup do
    stub(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end -> {:ok, []} end)
    :ok
  end

  describe "interactive connection tests" do
    test "one user hammering the button cannot exhaust another user's budget" do
      noisy = google_integration()
      quiet = google_integration()

      exhaust(fn -> Connection.test_connection(noisy) end)

      assert rate_limited?(Connection.test_connection(noisy))
      refute rate_limited?(Connection.test_connection(quiet))
    end

    test "a repeat connection test within the window is refused" do
      integration = google_integration()

      exhaust(fn -> Connection.test_connection(integration) end)

      assert rate_limited?(Connection.test_connection(integration))
    end

    test "charges the :oauth bucket directly, one token per test" do
      user = insert(:user)

      for _i <- 1..@limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(:oauth, {:user, user.id})
      end

      assert {:error, :rate_limited, message} =
               RateLimiter.check_connection_test_rate_limit(:oauth, {:user, user.id})

      assert message =~ "reached the limit"
    end
  end

  defp google_integration do
    insert(:calendar_integration, user: insert(:user), provider: "google")
  end

  defp exhaust(fun), do: Enum.each(1..@limit, fn _i -> fun.() end)

  defp rate_limited?({:error, {:rate_limited, message}}), do: message =~ "reached the limit"
  defp rate_limited?(_result), do: false
end
