defmodule Tymeslot.Integrations.Shared.ApiResponseTest do
  @moduledoc """
  The shared response envelope tells a provider that refused a request apart
  from one that was never reached: retry policy, the circuit breaker and the
  organiser's message all branch on the reason.
  """

  use ExUnit.Case, async: false

  @moduletag :calendar
  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Tymeslot.Integrations.Shared.ApiResponse
  alias Tymeslot.Test.LogCapture

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

  # A bare Graph 403 carries no body at all.
  test "an empty error body is a refusal" do
    assert {:error, :refused, _msg} =
             ApiResponse.with_error_object("", fn _msg, _decoded -> :unreachable end)
  end

  test "a provider's own classification comes first" do
    custom = fn _response -> {:error, :gone, "Gone"} end

    assert {:error, :gone, "Gone"} =
             ApiResponse.handle(status(410), label: "Test", custom: custom)
  end

  describe "handle_tagged/2" do
    defp tagged(response, opts \\ []) do
      {result, _log} =
        with_log(fn -> ApiResponse.handle_tagged(response, [label: "Video"] ++ opts) end)

      result
    end

    test "a success status decodes its body" do
      assert tagged(status(201, ~s({"id":"room"}))) == {:ok, %{"id" => "room"}}
    end

    test "an empty success body decodes to an empty map" do
      assert tagged(status(204)) == {:ok, %{}}
    end

    test "a success body that will not decode is :malformed_response" do
      assert tagged(status(200, "<html>proxy</html>")) == {:error, :malformed_response}
    end

    test "a status outside :success is an error, whatever it is" do
      assert {:error, {:http_error, 201, _message}} = tagged(status(201), success: [200])
    end

    test "an unmodelled status keeps its number and points at the logs" do
      assert tagged(status(503, "<html>down</html>")) ==
               {:error, {:http_error, 503, "Video API error (503): see logs for details"}}
    end

    test "the provider's own explanation is carried redacted" do
      body = ~s({"message":"bad token access_token=ya29.leaked"})

      assert {:error, {:http_error, 400, message}} =
               tagged(status(400, body), detail: & &1["message"])

      assert message =~ "Video API error (400): bad token"
      refute message =~ "ya29.leaked"
    end

    test "an explanation the provider did not give falls back to the logs" do
      assert {:error, {:http_error, 400, "Video API error (400): see logs for details"}} =
               tagged(status(400, "{}"), detail: & &1["message"])
    end

    test "a transport failure is passed through untouched" do
      error = %Mint.TransportError{reason: :econnrefused}
      assert tagged({:error, error}) == {:error, error}
    end

    test "a provider's own classification comes first" do
      custom = fn {:ok, %{status: 401}} -> {:error, :revoked} end
      assert tagged(status(401), custom: custom) == {:error, :revoked}
    end

    test "the unmodelled body is logged, redacted" do
      LogCapture.attach()

      ApiResponse.handle_tagged(status(500, ~s({"error":"token=ya29.leaked"})), label: "Video")

      logged = LogCapture.dump(LogCapture.await_log("Provider API error"))
      assert logged =~ "Video"
      refute logged =~ "ya29.leaked"
    end
  end
end
