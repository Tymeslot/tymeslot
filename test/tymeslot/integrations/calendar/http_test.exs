defmodule Tymeslot.Integrations.Calendar.HTTPTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  import Mox
  alias Tymeslot.Integrations.Calendar.HTTP

  setup :verify_on_exit!

  describe "segment/1" do
    test "encodes every reserved character, so the id stays one path segment" do
      assert HTTP.segment("en.uk#holiday@group.v.calendar.google.com") ==
               "en.uk%23holiday%40group.v.calendar.google.com"

      assert HTTP.segment("a/b?c d") == "a%2Fb%3Fc%20d"
    end

    test "leaves an id of unreserved characters as it is" do
      assert HTTP.segment("primary") == "primary"
      assert HTTP.segment("AAMk-ab_c.d~e") == "AAMk-ab_c.d~e"
    end
  end

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
