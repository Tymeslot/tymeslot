defmodule Tymeslot.Webhooks.HttpDeliveryPinningTest do
  @moduledoc """
  A webhook's SSRF verdict is made about a hostname. Unless the delivery then
  connects to the address that verdict approved, the HTTP client resolves the
  same name again at connect time and a short-TTL record can answer public to
  the check and loopback to the socket — DNS rebinding, which needs no redirect.

  These tests assert the delivery hands the approved address to the HTTP client
  as the connect target, and the original hostname alongside it so TLS and
  virtual-host routing still work. Every hop is checked separately, because
  each hop resolves separately.

  `:req_test_plug` is cleared here: the suite normally routes Req through a
  test plug, which opens no socket and is therefore deliberately never pinned.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :webhooks

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.HttpDelivery

  @approved {93, 184, 216, 34}
  @redirect_approved {198, 51, 100, 7}

  setup do
    setup_config(:tymeslot, :environment, :prod)
    setup_config(:tymeslot, :dns_resolver_module, Tymeslot.DnsResolverMock)
    setup_config(:tymeslot, :req_test_plug, nil)
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  defp approve(mapping) do
    stub(Tymeslot.DnsResolverMock, :resolve_public, fn url, _opts ->
      case Enum.find(mapping, fn {host, _address} -> String.contains?(url, host) end) do
        {_host, address} -> {:ok, [address]}
        nil -> {:error, "URL resolves to a private or local network address"}
      end
    end)
  end

  describe "post/4" do
    test "connects to the approved address and keeps the hostname for TLS and routing" do
      approve(%{"example.com" => @approved})

      expect(Tymeslot.HTTPClientMock, :post, 1, fn url, _body, _headers, opts ->
        assert url == "https://93.184.216.34/webhook"
        assert opts[:connect_options][:hostname] == "example.com"

        {:ok, %Req.Response{status: 200, body: "", headers: %{}}}
      end)

      assert {:ok, 200, _body} =
               HttpDelivery.post("https://example.com/webhook", "{}", [])
    end

    test "pins each redirect hop to the address that hop's own check approved" do
      approve(%{"example.com" => @approved, "elsewhere.example.net" => @redirect_approved})

      expect(Tymeslot.HTTPClientMock, :post, 1, fn url, _body, _headers, opts ->
        assert url == "https://93.184.216.34/webhook"
        assert opts[:connect_options][:hostname] == "example.com"

        {:ok,
         %Req.Response{
           status: 307,
           body: "",
           headers: %{"location" => ["https://elsewhere.example.net/next"]}
         }}
      end)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn url, _body, _headers, opts ->
        # A hop that re-used the first hop's pin would send the second request
        # to the first host's address, which is a different bug in the same
        # family: the connection would not go where the check looked.
        assert url == "https://198.51.100.7/next"
        assert opts[:connect_options][:hostname] == "elsewhere.example.net"

        {:ok, %Req.Response{status: 200, body: "", headers: %{}}}
      end)

      assert {:ok, 200, _body} =
               HttpDelivery.post("https://example.com/webhook", "{}", [])
    end

    test "a 302 hop switches to GET and is pinned just the same" do
      approve(%{"example.com" => @approved, "elsewhere.example.net" => @redirect_approved})

      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["https://elsewhere.example.net/next"]}
         }}
      end)

      expect(Tymeslot.HTTPClientMock, :get, 1, fn url, _headers, opts ->
        assert url == "https://198.51.100.7/next"
        assert opts[:connect_options][:hostname] == "elsewhere.example.net"

        {:ok, %Req.Response{status: 200, body: "", headers: %{}}}
      end)

      assert {:ok, 200, _body} =
               HttpDelivery.post("https://example.com/webhook", "{}", [])
    end

    test "delivers by hostname when the caller supplied no approved address" do
      # `skip_initial_check: true` without `:pin_addresses` is the pre-existing
      # contract; it must keep working rather than silently failing to deliver.
      expect(Tymeslot.HTTPClientMock, :post, 1, fn url, _body, _headers, opts ->
        assert url == "https://example.com/webhook"
        refute Keyword.has_key?(opts, :connect_options)

        {:ok, %Req.Response{status: 200, body: "", headers: %{}}}
      end)

      assert {:ok, 200, _body} =
               HttpDelivery.post("https://example.com/webhook", "{}", [],
                 skip_initial_check: true
               )
    end
  end

  describe "the Test Connection probe" do
    test "carries its approved address across the process boundary" do
      # This path validates in the caller and delivers inside a
      # `Task.Supervisor.async`, so the check and the connect are separated by
      # a process spawn and a JSON encode rather than a function call: the
      # widest rebinding window here, and the one that cannot re-derive the
      # address because `skip_initial_check: true` means nothing looks it up
      # again.
      approve(%{"example.com" => @approved})

      expect(Tymeslot.HTTPClientMock, :post, 1, fn url, _body, _headers, opts ->
        assert url == "https://93.184.216.34/webhook"
        assert opts[:connect_options][:hostname] == "example.com"

        {:ok, %Req.Response{status: 200, body: "", headers: %{}}}
      end)

      assert :ok = Webhooks.test_webhook_connection("https://example.com/webhook")
    end
  end
end
