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

  import Mox

  alias Tymeslot.Integrations.Video.Providers.CustomProvider

  # Must match @max_redirects in CustomProvider.
  @max_hops 3

  setup :verify_on_exit!

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

    test "follows exactly @max_redirects hops and reports the status of the last" do
      # A budget of #{@max_hops} redirects means #{@max_hops + 1} probes: the
      # URL itself plus one per hop. `verify_on_exit!` fails the test if the
      # probe stops early or runs one too many.
      expect(Tymeslot.HTTPClientMock, :head, @max_hops + 1, fn url, _headers, _opts ->
        if hop_index(url) == @max_hops do
          {:ok, %Req.Response{status: 200, headers: %{}}}
        else
          {:ok, redirect_from(url)}
        end
      end)

      assert {:ok, message} =
               CustomProvider.perform_connection_test(%{custom_meeting_url: hop_url(0)})

      assert message =~ "200"
    end

    test "refuses the hop one past the budget even though it would have answered" do
      # The same chain with the reachable page one hop further away, so the
      # budget is the only thing that fails the probe.
      expect(Tymeslot.HTTPClientMock, :head, @max_hops + 1, fn url, _headers, _opts ->
        if hop_index(url) == @max_hops + 1 do
          {:ok, %Req.Response{status: 200, headers: %{}}}
        else
          {:ok, redirect_from(url)}
        end
      end)

      assert {:error, message} =
               CustomProvider.perform_connection_test(%{custom_meeting_url: hop_url(0)})

      assert message =~ "redirects too many times"
    end

    test "follows a hop that stays on plain http" do
      # Video deliberately allows http: a self-hosted meeting server on an
      # internal network is a supported configuration. Webhook delivery is the
      # subsystem that enforces https, and its policy must not leak into this
      # one through the shared hop resolver.
      test_pid = self()

      Mox.stub(Tymeslot.HTTPClientMock, :head, fn url, _headers, _opts ->
        send(test_pid, {:probed, url})

        case url do
          @public_url ->
            {:ok,
             %Req.Response{
               status: 302,
               headers: %{"location" => ["http://203.0.113.20/final"]}
             }}

          _final ->
            {:ok, %Req.Response{status: 200, headers: %{}}}
        end
      end)

      assert {:ok, _message} =
               CustomProvider.perform_connection_test(%{custom_meeting_url: @public_url})

      assert_received {:probed, "http://203.0.113.20/final"}
    end

    test "reports a hop pointing at a non-http scheme as the redirect status" do
      Mox.stub(Tymeslot.HTTPClientMock, :head, fn url, _headers, _opts ->
        case url do
          @public_url ->
            {:ok,
             %Req.Response{
               status: 302,
               headers: %{"location" => ["ftp://203.0.113.20/final"]}
             }}

          other ->
            flunk("an ftp Location must never be probed, got #{other}")
        end
      end)

      assert {:ok, message} =
               CustomProvider.perform_connection_test(%{custom_meeting_url: @public_url})

      assert message =~ "302"
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

  # A chain of distinct hop URLs on a TEST-NET-3 literal, so no probe needs a
  # DNS lookup and each stub answer is derived from the URL it was handed.
  defp hop_url(n), do: "https://203.0.113.10/hop/#{n}"

  defp hop_index(url), do: url |> String.split("/") |> List.last() |> String.to_integer()

  defp redirect_from(url) do
    %Req.Response{status: 302, headers: %{"location" => [hop_url(hop_index(url) + 1)]}}
  end
end
