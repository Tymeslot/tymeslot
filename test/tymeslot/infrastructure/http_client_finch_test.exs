defmodule Tymeslot.Infrastructure.HTTPClientFinchTest do
  # Mutates the :req_test_plug application env, so it must not run alongside
  # the other HTTP client tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.HTTPClient

  # config/test.exs sets :req_test_plug, so every other HTTP client test routes
  # through the `:plug` branch of `req_transport_option/0`. That leaves the
  # `:finch` branch — the only one production ever takes — with no coverage at
  # all, which is how a malformed or deprecated Req adapter option could ship
  # green. Clearing the plug here exercises the real transport.
  setup do
    previous = Application.get_env(:tymeslot, :req_test_plug)
    Application.delete_env(:tymeslot, :req_test_plug)

    on_exit(fn -> Application.put_env(:tymeslot, :req_test_plug, previous) end)

    :ok
  end

  # Nothing listens on port 1, so the connection is refused. Getting as far as a
  # transport error is the assertion: Req validates adapter options before it
  # opens a connection, so a malformed `:finch` option raises instead.
  @refused_url "http://127.0.0.1:1/probe"

  describe "production Finch transport" do
    test "Req accepts the adapter options and reaches the network layer" do
      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               HTTPClient.get(@refused_url)
    end

    test "adapter options use a form Req does not deprecate" do
      # Req signals deprecated adapter options with IO.warn/1 rather than by
      # failing, so the request above would still pass on `finch: name`. This
      # is what actually catches a regression to a superseded option shape.
      stderr = capture_io(:stderr, fn -> HTTPClient.get(@refused_url) end)

      refute stderr =~ "deprecated",
             "Req reported a deprecated adapter option: #{stderr}"
    end
  end
end
