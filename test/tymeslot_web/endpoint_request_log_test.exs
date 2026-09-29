defmodule TymeslotWeb.EndpointRequestLogTest do
  # Not async: lowering the primary Logger level is global, and the absence
  # assertion must not see events logged by concurrently running tests.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :infrastructure
  @moduletag :integration

  alias Tymeslot.Test.LogCapture

  # The test env pins the logger at :warning, where the :info request line is
  # never emitted and an absence assertion would pass vacuously.
  defp request_log(fun) do
    LogCapture.with_capture([logger_level: :info], fun)
    Enum.map_join(LogCapture.drain(), "\n", &LogCapture.dump/1)
  end

  test "a meeting request link never reaches the request log", %{conn: conn} do
    token = "request-log-probe-#{System.unique_integer([:positive])}"

    log = request_log(fn -> get(conn, "/meeting-request/#{token}") end)

    refute log =~ token
  end

  test "an ordinary route still logs its request line", %{conn: conn} do
    log = request_log(fn -> get(conn, "/auth/login") end)

    assert log =~ "GET /auth/login"
  end
end
