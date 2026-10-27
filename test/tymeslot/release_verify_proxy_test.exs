defmodule Tymeslot.ReleaseVerifyProxyTest do
  @moduledoc """
  `Release.verify_proxy/1`, the proxy check an operator runs on a release
  with `bin/tymeslot eval`. Exercised without any network: the paths that
  decide before a request is sent.
  """

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  import ExUnit.CaptureIO

  alias Tymeslot.Release

  setup do
    original = Application.get_env(:tymeslot, :http_proxy)

    on_exit(fn ->
      if original,
        do: Application.put_env(:tymeslot, :http_proxy, original),
        else: Application.delete_env(:tymeslot, :http_proxy)
    end)
  end

  test "reports a missing proxy configuration and fails" do
    Application.delete_env(:tymeslot, :http_proxy)

    output =
      capture_io(fn -> assert {:error, :proxy_not_verified} = Release.verify_proxy() end)

    assert output =~ "[failed] Proxy configured"
    assert output =~ "No proxy configured"
    assert last_line(output) == "FAILED: proxy verification failed"
  end

  test "the quick check reports a missing proxy configuration and fails" do
    Application.delete_env(:tymeslot, :http_proxy)

    output =
      capture_io(fn -> assert {:error, _reason} = Release.verify_proxy(quick: true) end)

    assert last_line(output) =~ ~r/^FAILED: No proxy configured/
  end

  # The report goes to an operator's terminal and their support tickets: the
  # proxy password must not be in it.
  test "reports the configuration without the proxy's credentials" do
    Application.put_env(:tymeslot, :http_proxy, %{
      http_proxy: nil,
      https_proxy: %{
        host: "proxy.corp.example",
        port: 3128,
        scheme: :http,
        auth: {"svc-user", "s3cret-pass"}
      },
      no_proxy: ["httpbin.org"]
    })

    output = capture_io(fn -> assert {:error, _reason} = Release.verify_proxy() end)

    # The credential is acknowledged, not printed, and the URL stays a URL.
    assert output =~ "http://[configured]@proxy.corp.example:3128"
    assert output =~ "NO_PROXY: httpbin.org"
    assert output =~ "is in NO_PROXY list"
    refute output =~ "s3cret-pass"
  end

  # The verdict line is the contract a script relies on: `eval` exits 0
  # either way.
  defp last_line(output),
    do: output |> String.trim_trailing() |> String.split("\n") |> List.last()
end
