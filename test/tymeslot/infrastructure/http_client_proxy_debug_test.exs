defmodule Tymeslot.Infrastructure.HTTPClientProxyDebugTest do
  # Lowers the primary Logger level for the duration of the test; see
  # `Tymeslot.Test.LogCapture`'s moduledoc on why that forces async: false.
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Test.LogCapture

  setup do
    original_proxy = Application.get_env(:tymeslot, :http_proxy)

    Application.put_env(:tymeslot, :http_proxy, %{
      http_proxy: nil,
      # Loopback with no listener: the connect attempt is refused immediately,
      # so the test never depends on network access or waits out a timeout.
      https_proxy: %{host: "127.0.0.1", port: 1, auth: nil, scheme: "http"},
      no_proxy: []
    })

    on_exit(fn ->
      if original_proxy do
        Application.put_env(:tymeslot, :http_proxy, original_proxy)
      else
        Application.delete_env(:tymeslot, :http_proxy)
      end
    end)

    :ok
  end

  describe "a proxied request's connection pool" do
    test "does not collide with connection options the caller supplied" do
      # Req refuses `:finch` and `:connect_options` on one request and raises
      # rather than picking one, so a proxy — which is expressed as connection
      # options — cannot be combined with a named instance. Both the Exchange
      # client and the custom video probe pass connection options of their own,
      # so behind a proxy that is two sets on one request. The refusal here is
      # the proxy declining the connection, which is the whole point: what must
      # not happen is an ArgumentError before a socket is even attempted.
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               HTTPClient.get("https://example.com", [],
                 connect_options: [transport_opts: [verify: :verify_none]]
               )
    end

    test "is registered on the application's own Finch instance" do
      # Req answers connection options by starting a whole separate Finch
      # instance, named by an atom it derives from them and kept for the life
      # of the node, running on Finch's stock defaults rather than the pool
      # sizing and idle eviction configured here. The pool for a proxied
      # destination therefore has to be found on ours to know it is ours.
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               HTTPClient.get("https://proxied-pool.example.com")

      assert [tag] = shared_pool_tags("proxied-pool.example.com")
      assert tag =~ ~r/^[0-9a-f]{32}$/
    end
  end

  defp shared_pool_tags(host) do
    Tymeslot.Finch
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.filter(&match?({_scheme, ^host, _port, _tag}, &1))
    |> Enum.map(fn {_scheme, _host, _port, tag} -> tag end)
    |> Enum.uniq()
  end

  test "proxy debug log carries the request's scheme and host but never its path" do
    LogCapture.attach(logger_level: :debug)

    HTTPClient.get(
      "https://api.telegram.org/bot123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw/sendMessage"
    )

    event = LogCapture.await_log("Using proxy for request")
    meta = LogCapture.user_metadata(event)

    assert meta.url == "https://api.telegram.org"
    refute meta.url =~ "AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw"
    refute meta.url =~ "sendMessage"
  end
end
