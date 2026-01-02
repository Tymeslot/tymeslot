defmodule Tymeslot.Integrations.Calendar.HTTPTest do
  use ExUnit.Case, async: true
  alias Tymeslot.Integrations.Calendar.HTTP

  describe "request/5 method normalization" do
    test "accepts known string methods" do
      # Should return connection error rather than invalid_method
      result = HTTP.request("GET", "http://localhost:1", "/", "token")
      assert {:error, %HTTPoison.Error{reason: :econnrefused}} = result
    end

    test "rejects unknown string methods" do
      unknown = "INVALID"
      assert {:error, %HTTPoison.Error{reason: {:invalid_method, ^unknown}}} = HTTP.request(unknown, "http://base", "/path", "token")
    end

    test "is case-insensitive for string methods" do
      assert {:error, %HTTPoison.Error{reason: :econnrefused}} = HTTP.request("pOsT", "http://localhost:1", "/", "token")
    end
  end
end
