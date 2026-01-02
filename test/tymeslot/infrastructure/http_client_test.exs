defmodule Tymeslot.Infrastructure.HTTPClientTest do
  use ExUnit.Case, async: true
  alias Tymeslot.Infrastructure.HTTPClient

  describe "merge_options/3" do
    # Using private function testing via apply/3 or exposing it if needed.
    # Since it's internal logic, let's test it via public methods or helper if we can.
    # Actually, we can test it by calling post/4 and checking the options passed to
    # track_request or HTTPoison. But wait, HTTPClient is a wrapper. We can use Mox
    # to see what options were passed to HTTPoison if we had a mock for it.
    # For now, let's just add a test that verifies the logic by making merge_options
    # public or just testing the behavior.

    test "POST requests get longer timeouts" do
      # We'll use a trick to test the internal merge_options by calling a public method
      # but since we want to avoid actual network calls, we'll just check the logic if possible.
      # Given the current setup, let's add a test helper in the module or just test via
      # track_request metrics if they store options (they don't).

      # Actually, let's just make merge_options public for testing purposes or add a
      # test-only helper. Or even better, just verify the behavior via the module's
      # @operation_timeouts indirectly.

      # Since I can't easily intercept the HTTPoison call without more setup, I'll trust
      # the logic fix but I SHOULD add a unit test for the logic itself.

      options = HTTPClient.merge_options([], :post, "https://example.com")
      assert options[:timeout] == 45_000
      assert options[:recv_timeout] == 45_000

      get_options = HTTPClient.merge_options([], :get, "https://example.com")
      assert get_options[:timeout] == 30_000
    end

    test "user options override defaults and operation-specific timeouts" do
      options = HTTPClient.merge_options([timeout: 10_000], :post, "https://example.com")
      assert options[:timeout] == 10_000
    end
  end

  describe "request/5 method normalization" do
    test "accepts known string methods and converts to atoms" do
      # We use a mock or check internal call if possible, but here we can just check if it doesn't error
      # and if it correctly handles case.
      assert {:error, %HTTPoison.Error{reason: :econnrefused}} =
               HTTPClient.request("GET", "http://localhost:1")

      assert {:error, %HTTPoison.Error{reason: :econnrefused}} =
               HTTPClient.request("post", "http://localhost:1")
    end

    test "rejects unknown methods without creating atoms" do
      unknown_method = "UNKNOWN_VERB_#{:erlang.unique_integer()}"

      assert {:error, %HTTPoison.Error{reason: {:invalid_method, ^unknown_method}}} =
               HTTPClient.request(unknown_method, "http://example.com")

      # Verify atom was not created
      assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_method) end
    end
  end
end
