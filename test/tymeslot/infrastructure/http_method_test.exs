defmodule Tymeslot.Infrastructure.HTTPMethodTest do
  use ExUnit.Case, async: true
  @moduletag :infrastructure

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Calendar.HTTP, as: CalendarHTTP

  setup do
    ReqTest.stub(:tymeslot_http, fn conn ->
      Conn.send_resp(conn, 200, "ok")
    end)

    :ok
  end

  describe "HTTPClient.request method normalization" do
    test "accepts valid atom methods" do
      assert {:ok, %Req.Response{status: 200}} = HTTPClient.request(:get, "http://localhost/test")
    end

    test "accepts valid string methods (any case)" do
      assert {:ok, %Req.Response{status: 200}} =
               HTTPClient.request("GET", "http://localhost/test")

      assert {:ok, %Req.Response{status: 200}} =
               HTTPClient.request("post", "http://localhost/test")
    end

    test "rejects unknown string methods without creating atoms" do
      unknown = "not_a_real_method_#{:erlang.unique_integer()}"

      assert {:error, %RuntimeError{message: message}} =
               HTTPClient.request(unknown, "http://localhost:1")

      assert message =~ "Invalid HTTP method"

      # Verify atom was not created
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  describe "CalendarHTTP.normalize_method" do
    test "accepts valid atoms and strings" do
      # normalize_method is private, but we can test via request/5
      # We'll mock the request_fun to avoid network calls.
      mock_fun = fn method, _url, _body, _headers -> {:ok, method} end

      assert {:ok, :get} =
               CalendarHTTP.request("GET", "http://", "/", "token", request_fun: mock_fun)

      assert {:ok, :post} =
               CalendarHTTP.request(:post, "http://", "/", "token", request_fun: mock_fun)

      assert {:ok, :report} =
               CalendarHTTP.request("report", "http://", "/", "token", request_fun: mock_fun)
    end

    test "rejects unknown methods" do
      assert {:error, %RuntimeError{message: message}} =
               CalendarHTTP.request("BREW", "http://", "/", "token")

      assert message =~ "Invalid method"
    end
  end
end
