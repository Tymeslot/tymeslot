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
