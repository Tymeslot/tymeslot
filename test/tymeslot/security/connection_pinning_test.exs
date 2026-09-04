defmodule Tymeslot.Security.ConnectionPinningTest do
  @moduledoc """
  An SSRF verdict is made about a hostname; the socket is opened against
  whatever DNS says a moment later. Pinning is what makes the two the same
  answer, so these tests pin down both halves: that an approved address becomes
  the connect target, and that the original hostname still travels for TLS and
  routing.
  """
  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :unit

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Security.ConnectionPinning

  setup do
    # The suite normally routes Req through a test plug, which opens no socket
    # and so is never pinned. These tests are about the socket path.
    with_config(:tymeslot, :req_test_plug, nil)
    :ok
  end

  describe "pin/3" do
    test "connects to the approved address while keeping the hostname for TLS and routing" do
      assert {:ok, url, opts} =
               ConnectionPinning.pin("https://hooks.example.com/notify?x=1", [{93, 184, 216, 34}])

      assert url == "https://93.184.216.34/notify?x=1"

      # Mint uses :hostname for SNI, certificate verification and the Host
      # header, so a virtual-hosted target still routes and its certificate is
      # still checked against the name the user typed.
      assert opts[:connect_options][:hostname] == "hooks.example.com"
    end

    test "brackets an IPv6 literal so the colons are not read as a port" do
      assert {:ok, url, opts} =
               ConnectionPinning.pin("https://hooks.example.com/notify", [
                 {0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}
               ])

      assert url == "https://[2606:2800:220:1:248:1893:25c8:1946]/notify"
      assert opts[:connect_options][:hostname] == "hooks.example.com"
    end

    test "keeps the port and preserves the path" do
      assert {:ok, url, _opts} =
               ConnectionPinning.pin("https://hooks.example.com:8443/a/b", [{93, 184, 216, 34}])

      assert url == "https://93.184.216.34:8443/a/b"
    end

    test "does not pin when no address was approved" do
      # Nothing was resolved because nothing needed to be: the caller permitted
      # the URL on syntax alone, so there is no verdict to make binding.
      assert ConnectionPinning.pin("https://hooks.example.com/notify", []) == :unpinned
    end

    test "does not pin a host that is already an IP literal" do
      assert ConnectionPinning.pin("https://93.184.216.34/notify", [{93, 184, 216, 34}]) ==
               :unpinned
    end

    test "does not pin when a Req test plug is handling the request" do
      with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})

      assert ConnectionPinning.pin("https://hooks.example.com/notify", [{93, 184, 216, 34}]) ==
               :unpinned
    end

    test "does not pin when a proxy will open the socket instead" do
      # The proxy resolves the destination itself, so rewriting the host would
      # only change which destination we ask the proxy for.
      with_config(:tymeslot, :http_proxy, %{
        http_proxy: %{host: "proxy.internal", port: 3128, auth: nil, scheme: "http"},
        https_proxy: nil,
        no_proxy: []
      })

      assert ConnectionPinning.pin("http://hooks.example.com/notify", [{93, 184, 216, 34}]) ==
               :unpinned
    end

    test "pins a request that is already going direct past the configured proxy" do
      # `bypass_proxy: true` is the caller saying this one request leaves
      # directly however the environment is configured — `ProxyVerifier`
      # measures the unproxied origin that way. Nothing resolves the
      # destination on our behalf then, so the SSRF verdict can and must be
      # made binding.
      with_config(:tymeslot, :http_proxy, %{
        http_proxy: %{host: "proxy.internal", port: 3128, auth: nil, scheme: "http"},
        https_proxy: nil,
        no_proxy: []
      })

      assert {:ok, url, _opts} =
               ConnectionPinning.pin(
                 "http://hooks.example.com/notify",
                 [{93, 184, 216, 34}],
                 bypass_proxy: true
               )

      assert url == "http://93.184.216.34/notify"
    end
  end

  describe "pin_request/3" do
    test "merges the pinning options into the caller's own" do
      assert {url, opts} =
               ConnectionPinning.pin_request(
                 "https://hooks.example.com/notify",
                 [{93, 184, 216, 34}],
                 receive_timeout: 5_000,
                 redirect: false
               )

      assert url == "https://93.184.216.34/notify"
      assert opts[:receive_timeout] == 5_000
      assert opts[:redirect] == false
      assert opts[:connect_options][:hostname] == "hooks.example.com"
    end

    test "returns the request untouched when it cannot be pinned" do
      assert ConnectionPinning.pin_request("https://hooks.example.com/notify", [], a: 1) ==
               {"https://hooks.example.com/notify", [a: 1]}
    end

    test "keeps the caller's own connect options alongside the pinned hostname" do
      # The Exchange client turns certificate verification off for the
      # self-signed certificates on-premises deployments carry, and the custom
      # video probe budgets a connect timeout. A flat merge would replace both
      # with the pin's lone :hostname, quietly reinstating verification the
      # operator switched off.
      assert {_url, opts} =
               ConnectionPinning.pin_request(
                 "https://exchange.example.com/EWS/Exchange.asmx",
                 [{93, 184, 216, 34}],
                 connect_options: [transport_opts: [verify: :verify_none], timeout: 3_000]
               )

      assert opts[:connect_options][:transport_opts] == [verify: :verify_none]
      assert opts[:connect_options][:timeout] == 3_000
      assert opts[:connect_options][:hostname] == "exchange.example.com"
    end

    test "lets the pinned hostname win a collision with the caller's" do
      assert {_url, opts} =
               ConnectionPinning.pin_request(
                 "https://hooks.example.com/notify",
                 [{93, 184, 216, 34}],
                 connect_options: [hostname: "stale.example.com"]
               )

      assert opts[:connect_options][:hostname] == "hooks.example.com"
    end
  end
end
