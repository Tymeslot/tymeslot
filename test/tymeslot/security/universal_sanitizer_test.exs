defmodule Tymeslot.Security.UniversalSanitizerTest do
  use ExUnit.Case, async: true
  @moduletag :security

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

    test "removes malicious patterns recursively" do
      # Recursive path traversal
      assert {:ok, "etc/passwd"} =
               UniversalSanitizer.sanitize_and_validate("....//etc/passwd", log_events: false)

      # Nested SQL injection patterns
      # "UNION UNION SELECT SELECT" should be fully removed
      assert {:ok, "normal text"} =
               UniversalSanitizer.sanitize_and_validate("UNION UNION SELECT SELECT normal text",
                 log_events: false
               )
    end

    test "removes null bytes before other sanitization to prevent keyword breaking" do
      # If null bytes are removed after SQL sanitization, this would become "UNION SELECT "
      input = "UN\x00ION SEL\x00ECT "
      assert {:ok, sanitized} = UniversalSanitizer.sanitize_and_validate(input, log_events: false)
      refute sanitized =~ "UNION"
      refute sanitized =~ "SELECT"
    end

    test "preserves CalDAV calendar paths with @ symbols and slashes" do
      # CalDAV paths often contain @ symbols (from email addresses) and slashes
      caldav_paths = [
        "/dav/user@example.com/Calendar/",
        "/remote.php/dav/calendars/admin@domain.org/personal/",
        "/caldav/principals/test@company.com/calendars/primary/",
        "/dav/user@zimbra.example.org/Calendar/Tasks/"
      ]

      for path <- caldav_paths do
        assert {:ok, sanitized} =
                 UniversalSanitizer.sanitize_and_validate(path, log_events: false)

        # CalDAV paths should remain unchanged
        assert sanitized == path,
               "Expected CalDAV path #{path} to remain unchanged, got #{sanitized}"
      end
    end

    test "preserves Zimbra-style CalDAV paths" do
      # Specific test for Zimbra format (related to issue #8)
      zimbra_path = "/dav/alice@example.org/Calendar/"

      assert {:ok, sanitized} =
               UniversalSanitizer.sanitize_and_validate(zimbra_path, log_events: false)

      assert sanitized == zimbra_path
    end

    test "preserves ampersands and other plain-text characters unchanged" do
      # Plain-text fields round-trip through the sanitizer into LiveView form
      # values and back — entity-encoding `&`, `<`, `>`, `"`, `'` here causes
      # double-escaping at render time. Values without any HTML tags must come
      # out byte-identical so "Paul & Luka" does not become "Paul &amp; Luka".
      inputs = [
        "Paul & Luka",
        "Terms & Conditions",
        "R&D Update",
        ~s(She said "hello"),
        "It's fine"
      ]

      for input <- inputs do
        assert {:ok, ^input} =
                 UniversalSanitizer.sanitize_and_validate(input, log_events: false),
               "Expected #{inspect(input)} to round-trip unchanged"
      end
    end

    test "strips HTML tags without entity-encoding surrounding text" do
      assert {:ok, "XSSLabel"} =
               UniversalSanitizer.sanitize_and_validate("<script>XSS</script>Label",
                 log_events: false
               )

      assert {:ok, "Hello & goodbye"} =
               UniversalSanitizer.sanitize_and_validate("<b>Hello</b> & goodbye",
                 log_events: false
               )
    end

    test "preserves Nextcloud CalDAV paths" do
      # Nextcloud uses a different path structure
      nextcloud_path = "/remote.php/dav/calendars/user@nextcloud.com/personal/"

      assert {:ok, sanitized} =
               UniversalSanitizer.sanitize_and_validate(nextcloud_path, log_events: false)

      assert sanitized == nextcloud_path
    end
  end
end
