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
  alias Tymeslot.Integrations.Video.Connection

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

      assert {:error, message} = Connection.test_connection(noisy_user.id, noisy_integration.id)
      assert message =~ "reached the limit"

      assert {:ok, "Connection successful - API key is valid"} =
               Connection.test_connection(quiet_user.id, quiet_integration.id)
    end
  end

  describe "scheduled health probes" do
    test "cannot starve the owner's interactive check" do
      {user, integration} = mirotalk_integration()

      exhaust(fn -> Assessor.test_integration(:video, integration) end)

      # The background bucket is real — it just belongs to the integration.
      assert {:error, message} = Assessor.test_integration(:video, integration)
      assert message =~ "reached the limit"

      assert {:ok, "Connection successful - API key is valid"} =
               Connection.test_connection(user.id, integration.id)
    end

    test "probing one integration does not starve probes of another" do
      {_user_a, integration_a} = mirotalk_integration()
      {_user_b, integration_b} = mirotalk_integration()

      exhaust(fn -> Assessor.test_integration(:video, integration_a) end)

      assert {:error, _message} = Assessor.test_integration(:video, integration_a)

      assert {:ok, "Connection successful - API key is valid"} =
               Assessor.test_integration(:video, integration_b)
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
