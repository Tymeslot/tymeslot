defmodule Tymeslot.Infrastructure.HTTPMethodTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Calendar.HTTP, as: CalendarHTTP

  describe "HTTPClient.request method normalization" do
    test "accepts valid atom methods" do
      # We don't want to make actual requests, so we check if it reaches merge_options correctly.
      # Since we can't easily mock HTTPoison without Mox, and we are testing the logic
      # before the call, we'll just verify it doesn't return an invalid method error for known atoms.

      # We'll use a bogus URL to trigger a network error instead of a validation error
      assert {:error, %HTTPoison.Error{reason: reason}} = HTTPClient.request(:get, "http://localhost:1")
      assert reason != {:invalid_method, :get}
    end

    test "accepts valid string methods (any case)" do
      assert {:error, %HTTPoison.Error{reason: reason}} = HTTPClient.request("GET", "http://localhost:1")
      assert reason != {:invalid_method, "GET"}

      assert {:error, %HTTPoison.Error{reason: reason}} = HTTPClient.request("post", "http://localhost:1")
      assert reason != {:invalid_method, "post"}
    end

    test "rejects unknown string methods without creating atoms" do
      unknown = "not_a_real_method_#{:erlang.unique_integer()}"

      assert {:error, %HTTPoison.Error{reason: {:invalid_method, ^unknown}}} =
               HTTPClient.request(unknown, "http://localhost:1")

      # Verify atom was not created
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    end
  end

  describe "CalendarHTTP.normalize_method" do
    test "accepts valid atoms and strings" do
      # normalize_method is private, but we can test via request/5
      # We'll mock the request_fun to avoid network calls.
      mock_fun = fn method, _url, _body, _headers -> {:ok, method} end

      assert {:ok, :get} = CalendarHTTP.request("GET", "http://", "/", "token", request_fun: mock_fun)
      assert {:ok, :post} = CalendarHTTP.request(:post, "http://", "/", "token", request_fun: mock_fun)
      assert {:ok, :report} = CalendarHTTP.request("report", "http://", "/", "token", request_fun: mock_fun)
    end

    test "rejects unknown methods" do
      assert {:error, %HTTPoison.Error{reason: {:invalid_method, "BREW"}}} =
               CalendarHTTP.request("BREW", "http://", "/", "token")
    end
  end
end
