defmodule Tymeslot.Integrations.Calendar.Shared.ApiResponseTest do
  @moduledoc """
  The shared response envelope tells a provider that refused a request apart
  from one that was never reached: retry policy, the circuit breaker and the
  organiser's message all branch on the reason.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Calendar.Shared.ApiResponse

  defp handle(response) do
    {result, _log} = with_log(fn -> ApiResponse.handle(response, label: "Test") end)
    result
  end

  defp status(status, body \\ ""), do: {:ok, %{status: status, body: body, headers: %{}}}

  for code <- [400, 403, 405, 409, 410, 412, 422] do
    test "a #{code} is :refused" do
      assert handle(status(unquote(code))) ==
               {:error, :refused, "HTTP #{unquote(code)} (see logs for details)"}
    end
  end

  test "a 401 is :unauthorized" do
    assert {:error, :unauthorized, _msg} = handle(status(401))
  end

  test "a 404 is :not_found" do
    assert {:error, :not_found, _msg} = handle(status(404))
  end

  test "a 429 is :rate_limited" do
    assert {:error, :rate_limited, _msg} = handle(status(429))
  end

  test "a 408 is :timeout, which a resend may get through" do
    assert {:error, :timeout, _msg} = handle(status(408))
  end

  test "a 5xx is :server_error" do
    assert {:error, :server_error, "HTTP 503"} = handle(status(503))
  end

  test "a status outside 4xx no clause names stays :network_error" do
    assert {:error, :network_error, _msg} = handle(status(302))
  end

  test "a transport failure is :network_error" do
    assert {:error, :network_error, _msg} =
             handle({:error, %Mint.TransportError{reason: :econnrefused}})
  end

  test "a success body that will not decode is :malformed_response" do
    assert {:error, :malformed_response, "Malformed JSON response"} =
             handle(status(200, "<html>proxy</html>"))
  end

  test "an error body that will not decode is a refusal" do
    assert {:error, :refused, _msg} =
             ApiResponse.with_error_object("<html>", fn _msg, _decoded -> :unreachable end)
  end

  test "a provider's own classification comes first" do
    custom = fn _response -> {:error, :gone, "Gone"} end

    assert {:error, :gone, "Gone"} =
             ApiResponse.handle(status(410), label: "Test", custom: custom)
  end
end
