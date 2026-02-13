defmodule Tymeslot.Infrastructure.HTTPClientTest do
  use ExUnit.Case, async: true
  alias Tymeslot.Infrastructure.HTTPClient

  # merge_options/3 tests removed - this function no longer exists with Req.
  # Timeout configuration is now handled via @operation_timeouts and get_timeout/2.

  describe "request/5 method normalization" do
    test "accepts known string methods and converts to atoms" do
      # We use a mock or check internal call if possible, but here we can just check if it doesn't error
      # and if it correctly handles case.
      assert {:error, exception} =
               HTTPClient.request("GET", "http://localhost:1")

      assert is_exception(exception)

      assert {:error, exception} =
               HTTPClient.request("post", "http://localhost:1")

      assert is_exception(exception)
    end

    test "rejects unknown methods without creating atoms" do
      unknown_method = "UNKNOWN_VERB_#{:erlang.unique_integer()}"

      assert {:error, %RuntimeError{message: message}} =
               HTTPClient.request(unknown_method, "http://example.com")

      assert message =~ "Invalid HTTP method"

      # Verify atom was not created
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_method) end
    end
  end
end
