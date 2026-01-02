defmodule Tymeslot.Security.UniversalSanitizerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Tymeslot.Security.UniversalSanitizer

  describe "sanitize_and_validate/2" do
    test "rejects invalid UTF-8 input without raising" do
      invalid = <<0xC3, 0x28>>

      log =
        capture_log(fn ->
          assert {:error, "Invalid text encoding"} =
                   UniversalSanitizer.sanitize_and_validate(invalid,
                     log_events: true,
                     metadata: %{ip: "127.0.0.1"}
                   )
        end)

      assert log =~ "Malicious input blocked"
    end

    test "enforces max_input_bytes with error by default" do
      input = String.duplicate("a", 11)

      assert {:error, "Input exceeds maximum size (10 bytes)"} =
               UniversalSanitizer.sanitize_and_validate(input,
                 max_input_bytes: 10,
                 log_events: false
               )
    end

    test "truncates to max_input_bytes when configured" do
      input = String.duplicate("a", 20)

      assert {:ok, output} =
               UniversalSanitizer.sanitize_and_validate(input,
                 max_input_bytes: 10,
                 on_too_long: :truncate,
                 log_events: false
               )

      assert output == String.duplicate("a", 10)
      assert byte_size(output) <= 10
    end

    test "enforces max_length on sanitized output by default" do
      assert {:error, "Input exceeds maximum length (3 characters)"} =
               UniversalSanitizer.sanitize_and_validate("abcd",
                 max_length: 3,
                 log_events: false
               )
    end

    test "truncates to max_length and logs an event when configured" do
      log =
        capture_log([level: :info], fn ->
          assert {:ok, "abc"} =
                   UniversalSanitizer.sanitize_and_validate("abcd",
                     max_length: 3,
                     on_too_long: :truncate,
                     log_events: true,
                     metadata: %{ip: "127.0.0.1"}
                   )
        end)

      assert log =~ "Input truncated"
    end

    test "sanitizes nested maps with the same options" do
      assert {:ok, %{"name" => "abc"}} =
               UniversalSanitizer.sanitize_and_validate(%{"name" => "abcd"},
                 max_length: 3,
                 on_too_long: :truncate,
                 log_events: false
               )
    end
  end
end
