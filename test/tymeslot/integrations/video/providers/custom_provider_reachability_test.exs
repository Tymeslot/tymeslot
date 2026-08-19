defmodule Tymeslot.Integrations.Video.Providers.CustomProviderReachabilityTest do
  @moduledoc """
  The reachability probe behind "Test connection" on a custom video
  integration. The host is whatever the dashboard user typed, and the probe
  reports HTTP status, timeout and connection-refused apart, so a host that
  resolves publicly and then redirects into the private range would turn it
  into an internal port scanner.
  """

  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Providers.CustomProvider

  describe "perform_connection_test/1 — redirect handling" do
    # An IP literal in TEST-NET-3: `:inet.getaddrs/2` parses it without a DNS
    # lookup, so the pre-flight public-host check passes with no network.
    @public_url "https://203.0.113.10/room"

    test "asks the HTTP client to guard every request it makes" do
      test_pid = self()

      Mox.stub(Tymeslot.HTTPClientMock, :head, fn _url, _headers, opts ->
        send(test_pid, {:probe_opts, opts})
        {:ok, %Req.Response{status: 200, headers: %{}}}
      end)

      assert {:ok, _message} =
               CustomProvider.perform_connection_test(%{
                 custom_meeting_url: @public_url
               })

      assert_received {:probe_opts, opts}
      assert Keyword.get(opts, :ssrf_protect) == true
      # `ssrf_protect` forcibly disables redirects, and classifies only the URL
      # it is handed, so asking the client to follow them would be a no-op that
      # reads as protection.
      refute Keyword.get(opts, :redirect)
    end

    test "follows a redirect as a fresh guarded request rather than in one call" do
      test_pid = self()

      Mox.stub(Tymeslot.HTTPClientMock, :head, fn url, _headers, _opts ->
        send(test_pid, {:probed, url})

        case url do
          @public_url ->
            {:ok,
             %Req.Response{
               status: 302,
               headers: %{"location" => ["https://203.0.113.20/final"]}
             }}

          _final ->
            {:ok, %Req.Response{status: 200, headers: %{}}}
        end
      end)

      assert {:ok, _message} =
               CustomProvider.perform_connection_test(%{
                 custom_meeting_url: @public_url
               })

      assert_received {:probed, @public_url}
      assert_received {:probed, "https://203.0.113.20/final"}
    end

    test "gives up on a redirect loop instead of following it forever" do
      Mox.stub(Tymeslot.HTTPClientMock, :head, fn url, _headers, _opts ->
        next = url <> "/on"

        {:ok, %Req.Response{status: 302, headers: %{"location" => [next]}}}
      end)

      assert {:error, message} =
               CustomProvider.perform_connection_test(%{
                 custom_meeting_url: @public_url
               })

      assert message =~ "redirects too many times"
    end

    test "reports a blocked hop as a private address rather than as unreachable" do
      Mox.stub(Tymeslot.HTTPClientMock, :head, fn url, _headers, _opts ->
        {:error, %Tymeslot.Security.SsrfBlockedError{url: url, reason: :private_address}}
      end)

      assert {:error, message} =
               CustomProvider.perform_connection_test(%{
                 custom_meeting_url: @public_url
               })

      assert message =~ "private or loopback"
    end
  end
end
