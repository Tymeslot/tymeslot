defmodule Tymeslot.Integrations.Video.Providers.CustomProviderSsrfTest do
  @moduledoc """
  Covers the request-time half of the video private-IP opt-out: the reachability
  probe behind the custom provider's "test" button.

  That probe used to run its own hand-rolled `:inet.getaddr/2` check, which no
  config key could switch off and which fired in every environment. Reaching an
  internal meeting server was therefore impossible however the operator
  configured the deployment. These tests pin the replacement: the probe goes
  through `SsrfGuard` with the video-scoped allowance, so it is blocked by
  default and permitted once the operator opts in.

  The blocked cases stub `Req.Test` with `flunk/1`: if `ssrf_protect: true` ever
  goes missing from the call site, the request reaches the stub and the test
  fails rather than quietly passing.
  """

  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :security

  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Video.Providers.CustomProvider

  @private_host_url "https://meet.corp.internal/room-42"

  setup do
    # The real HTTPClient, so the ssrf_protect option is actually evaluated.
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :environment, :prod)
    with_config(:tymeslot, :allow_private_ips_for_calendar, false)
    with_config(:tymeslot, :allow_private_ips_for_video, false)
    with_config(:tymeslot, :dns_resolver_module, CustomProviderSsrfPrivateResolver)
    :ok
  end

  defp refuse_network(message) do
    ReqTest.stub(:tymeslot_http, fn _conn -> flunk(message) end)
  end

  defp respond(status) do
    ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, status, "") end)
  end

  defp test_connection(url \\ @private_host_url) do
    CustomProvider.perform_connection_test(%{custom_meeting_url: url})
  end

  describe "perform_connection_test/1 with no opt-out" do
    test "blocks a host that resolves to a private address" do
      refuse_network("the probe must not reach a private host while the opt-out is off")

      assert {:error, message} = test_connection()
      assert message == "URL resolves to a private or loopback address"
    end

    test "blocks a literal private address too" do
      refuse_network("the probe must not reach a private address while the opt-out is off")

      assert {:error, message} = test_connection("http://192.168.1.10:8443/room")
      assert message == "URL resolves to a private or loopback address"
    end
  end

  describe "perform_connection_test/1 with the video opt-out" do
    test "reaches a private host and reports the status it answered with" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)
      respond(200)

      assert {:ok, "URL responded with HTTP 200"} = test_connection()
    end

    test "reports a non-2xx answer from a private host as a failure" do
      with_config(:tymeslot, :allow_private_ips_for_video, true)
      respond(503)

      assert {:error, "URL responded with HTTP 503"} = test_connection()
    end

    test "ALLOW_PRIVATE_IPS_FOR_CALENDAR still satisfies video, for deployments that set it" do
      with_config(:tymeslot, :allow_private_ips_for_calendar, true)
      respond(200)

      assert {:ok, "URL responded with HTTP 200"} = test_connection()
    end
  end

  describe "perform_connection_test/1 outside production" do
    test "reaches a private host, so a local meeting server is testable in development" do
      with_config(:tymeslot, :environment, :dev)
      respond(200)

      assert {:ok, "URL responded with HTTP 200"} = test_connection()
    end
  end

  test "a non-HTTP scheme is still rejected before any request is made" do
    refuse_network("a non-HTTP URL must never reach the network")

    assert {:error, message} = test_connection("ftp://meet.example.com/room")
    assert message =~ "Only http and https"
  end
end

defmodule CustomProviderSsrfPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
