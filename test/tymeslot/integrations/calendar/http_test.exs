defmodule Tymeslot.Integrations.Calendar.HTTPTest do
  @moduletag :integrations
  use ExUnit.Case, async: true
  import Mox
  alias Tymeslot.Integrations.Calendar.HTTP

  setup :verify_on_exit!
  @moduletag :integrations

  describe "request/5 method normalization" do
    test "accepts known string methods" do
      expect(Tymeslot.HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "ok"}}
      end)

      result = HTTP.request("GET", "http://localhost:1", "/", "token")
      assert {:ok, %Req.Response{status: 200}} = result
    end

    test "rejects unknown string methods" do
      unknown = "INVALID"

      assert {:error, %RuntimeError{message: message}} =
               HTTP.request(unknown, "http://base", "/path", "token")

      assert message =~ "Invalid method"
    end

    test "is case-insensitive for string methods" do
      expect(Tymeslot.HTTPClientMock, :request, fn :post, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: "created"}}
      end)

      assert {:ok, %Req.Response{status: 201}} =
               HTTP.request("pOsT", "http://localhost:1", "/", "token")
    end
  end
end
