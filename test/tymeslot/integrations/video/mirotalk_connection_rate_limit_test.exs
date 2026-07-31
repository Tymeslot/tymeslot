defmodule Tymeslot.Integrations.Video.MiroTalkConnectionRateLimitTest do
  @moduledoc """
  The MiroTalk connection-test bucket must be partitioned by whoever asked for
  the test.

  It used to be keyed on an `ip_address` that defaulted to `"127.0.0.1"` because
  no server-side caller ever supplied one, so every connection check on the
  whole instance — scheduled health probes, the settings "Test connection"
  button, integration setup — drew from a single bucket of 20 per 10 minutes.
  """

  # Synchronous like the other rate-limiter suites: several async tests call
  # `RateLimiter.clear_all/0`, which wipes the shared ETS table these counts
  # depend on.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :security

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.HealthCheck.Assessor
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.Connection
  alias Tymeslot.Security.RateLimiter

  # The bucket allows 20 connection tests per 10 minutes per scope.
  @limit 20

  setup :verify_on_exit!

  setup do
    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 200, body: "{}"}}
    end)

    :ok
  end

  describe "interactive connection tests" do
    test "one user hammering the button cannot exhaust another user's budget" do
      {noisy_user, noisy_integration} = mirotalk_integration()
      {quiet_user, quiet_integration} = mirotalk_integration()

      exhaust(fn -> Connection.test_connection(noisy_user.id, noisy_integration.id) end)

      assert {:error, {:rate_limited, message}} =
               Connection.test_connection(noisy_user.id, noisy_integration.id)

      assert message =~ "reached the limit"

      assert {:ok, "Connection successful - API key is valid"} =
               Connection.test_connection(quiet_user.id, quiet_integration.id)
    end
  end

  describe "scheduled health probes" do
    # `ConnectionProbe` treats `scope: :background` as unmetered by
    # construction (see its moduledoc): the scheduler already owns its own
    # cadence — a 30-minute floor plus its own exponential backoff — so a
    # token bucket protects nothing there and only adds a way for the
    # scheduler's own result to be corrupted by an unrelated refusal.
    test "running well past the interactive limit never trips a refusal" do
      {_user, integration} = mirotalk_integration()

      for _i <- 1..(@limit * 2) do
        assert {:ok, "Connection successful - API key is valid"} =
                 Assessor.test_integration(:video, integration)
      end
    end

    test "does not draw from the owner's interactive bucket" do
      {user, integration} = mirotalk_integration()

      exhaust(fn -> Assessor.test_integration(:video, integration) end)

      assert {:ok, "Connection successful - API key is valid"} =
               Connection.test_connection(user.id, integration.id)
    end
  end

  describe "integration creation" do
    # `Video.do_create_integration/2`'s MiroTalk pre-check now routes through
    # `Connection.probe/3` — the same choke point the "Test connection"
    # button uses — rather than reimplementing the bucket lookup and charge.
    # These two tests pin that: setup draws from the same per-user bucket,
    # and each attempt charges exactly one token.
    test "creating an integration draws from the same per-user bucket the Test connection button uses" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, provider: "mirotalk")

      exhaust(fn -> Connection.test_connection(user.id, integration.id) end)

      attrs = %{
        "name" => "New MiroTalk",
        "base_url" => "https://mirotalk-new.test",
        "api_key" => "test-key"
      }

      assert {:error, {:rate_limited, message}} =
               Video.create_integration(user.id, :mirotalk, attrs)

      assert message =~ "reached the limit"
    end

    test "creating an integration charges exactly one token to the submitting user" do
      user = insert(:user)

      for i <- 1..@limit do
        attrs = %{
          "name" => "MiroTalk #{i}",
          "base_url" => "https://mirotalk-#{i}.test",
          "api_key" => "test-key"
        }

        assert {:ok, _integration} = Video.create_integration(user.id, :mirotalk, attrs)
      end

      over_budget_attrs = %{
        "name" => "MiroTalk over budget",
        "base_url" => "https://mirotalk-over-budget.test",
        "api_key" => "test-key"
      }

      assert {:error, {:rate_limited, message}} =
               Video.create_integration(user.id, :mirotalk, over_budget_attrs)

      assert message =~ "reached the limit"
    end

    # `Connection.probe/3` now runs `validate_config/1` before charging a
    # token (see its moduledoc), so a structurally invalid submission never
    # draws from the bucket — it used to burn one anyway via
    # `ProviderRegistry.test_provider_connection/2`'s embedded validation.
    test "a structurally invalid config is rejected without ever touching the rate limiter" do
      user = insert(:user)
      attrs = %{"name" => "Bad MiroTalk", "api_key" => "test-key"}

      for _i <- 1..(@limit + 5) do
        assert {:error, _reason} = Video.create_integration(user.id, :mirotalk, attrs)
      end

      # The full per-user budget is still available: none of the failed
      # structural checks above drew from it.
      for _i <- 1..@limit do
        assert :ok = RateLimiter.check_connection_test_rate_limit(:mirotalk, {:user, user.id})
      end

      assert {:error, :rate_limited, _message} =
               RateLimiter.check_connection_test_rate_limit(:mirotalk, {:user, user.id})
    end
  end

  defp mirotalk_integration do
    user = insert(:user)
    {user, insert(:video_integration, user: user, provider: "mirotalk")}
  end

  defp exhaust(fun) do
    Enum.each(1..@limit, fn _i -> fun.() end)
  end
end
