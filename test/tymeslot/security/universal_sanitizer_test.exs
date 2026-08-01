defmodule Tymeslot.Security.UniversalSanitizerTest do
  use ExUnit.Case, async: true
  @moduletag :security

  import ExUnit.CaptureLog

  alias Tymeslot.Security.UniversalSanitizer

  defmodule LoggerForwarder do
    @moduledoc false
    # Erlang :logger handler that forwards each log event to a test process
    # as `{tag, message, metadata}`, so tests can assert on structured
    # metadata that Logger's default format does not surface.

    @spec log(map(), map()) :: :ok
    def log(%{msg: msg, meta: meta}, %{config: %{target: target, tag: tag}}) do
      message = normalise_msg(msg)
      send(target, {tag, message, meta})
      :ok
    end

    defp normalise_msg({:string, str}), do: IO.iodata_to_binary(str)
    defp normalise_msg({:report, report}) when is_map(report), do: report[:message] || ""

    defp normalise_msg({:report, report}) when is_list(report),
      do: to_string(report[:message] || "")

    defp normalise_msg({format, args}) when is_list(format) do
      IO.iodata_to_binary(:io_lib.format(format, args))
    end

    defp normalise_msg(other), do: inspect(other)
  end

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

      assert log =~ "Suspicious input sanitised"
    end

    test "invalid UTF-8 log carries the caller-supplied field name" do
      invalid = <<0xC3, 0x28>>

      {events, _log} =
        with_captured_warnings(fn ->
          UniversalSanitizer.sanitize_and_validate(invalid,
            log_events: true,
            field: :name,
            metadata: %{ip: "127.0.0.1"}
          )
        end)

      assert Enum.any?(events, fn event ->
               event.message == "Suspicious input sanitised" and
                 event.metadata[:field] == :name and
                 event.metadata[:check] == "invalid_encoding"
             end),
             "expected a warning with field=:name and check=\"invalid_encoding\", got: #{inspect(events)}"
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

    test "logs the caller-supplied field name and the specific check that fired" do
      {events, _log} =
        with_captured_warnings(fn ->
          UniversalSanitizer.sanitize_and_validate("bob' OR '1'='1",
            log_events: true,
            field: :email,
            metadata: %{ip: "127.0.0.1"}
          )
        end)

      assert Enum.any?(events, fn event ->
               event.message == "Suspicious input sanitised" and
                 event.metadata[:field] == :email and
                 event.metadata[:check] == "sql_injection"
             end),
             "expected a warning with field=:email and check=\"sql_injection\", got: #{inspect(events)}"

      # Must not regress to the old pattern where the check was logged as the field.
      refute Enum.any?(events, fn event ->
               event.metadata[:field] == :sql_injection
             end)
    end

    test "rejects percent-encoded input that decodes to invalid UTF-8" do
      # 0xE9 alone is a lone continuation-less byte: invalid UTF-8. The raw
      # input "Jos%E9 Smith" is valid UTF-8 (it's plain ASCII with a literal
      # '%'), so the pre-decode gate lets it through; without a post-decode
      # re-check this reaches the database as invalid UTF-8 and raises.
      assert {:error, "Invalid text encoding"} =
               UniversalSanitizer.sanitize_and_validate("Jos%E9 Smith", log_events: false)
    end

    test "still accepts percent-encoded input that decodes to valid UTF-8" do
      assert {:ok, "José"} =
               UniversalSanitizer.sanitize_and_validate("Jos%C3%A9", log_events: false)
    end

    test "defaults field to :unknown when caller omits it" do
      {events, _log} =
        with_captured_warnings(fn ->
          UniversalSanitizer.sanitize_and_validate("bob' OR '1'='1", log_events: true)
        end)

      assert Enum.any?(events, fn event ->
               event.metadata[:field] == :unknown and
                 event.metadata[:check] == "sql_injection"
             end)
    end
  end

  describe "mode: :plain_text" do
    test "preserves angle-bracket symbols that strict mode would strip" do
      preserved = [
        "Luka <> Paul",
        "1 < 2 > 0",
        "<email@example.com>",
        "<3 my team",
        "value <- pipe",
        "a<b>c"
      ]

      for input <- preserved do
        assert {:ok, ^input} =
                 UniversalSanitizer.sanitize_and_validate(input,
                   mode: :plain_text,
                   log_events: false
                 ),
               "Expected #{inspect(input)} to round-trip unchanged in :plain_text mode"
      end
    end

    test "preserves SQL-comment and dangerous-protocol substrings as plain text" do
      preserved = [
        "Lunch -- 30 min",
        "deploy /* prod */ today",
        "talk about javascript: best practices",
        "'; DROP TABLE users; --",
        "../assets/logo.png"
      ]

      for input <- preserved do
        assert {:ok, ^input} =
                 UniversalSanitizer.sanitize_and_validate(input,
                   mode: :plain_text,
                   log_events: false
                 ),
               "Expected #{inspect(input)} to round-trip unchanged in :plain_text mode"
      end
    end

    test "still validates UTF-8" do
      invalid = <<0xC3, 0x28>>

      assert {:error, "Invalid text encoding"} =
               UniversalSanitizer.sanitize_and_validate(invalid,
                 mode: :plain_text,
                 log_events: false
               )
    end

    test "still strips null bytes" do
      assert {:ok, "abdef"} =
               UniversalSanitizer.sanitize_and_validate("ab\x00def",
                 mode: :plain_text,
                 log_events: false
               )
    end

    test "still enforces max_length" do
      assert {:error, "Input exceeds maximum length (3 characters)"} =
               UniversalSanitizer.sanitize_and_validate("abcd",
                 mode: :plain_text,
                 max_length: 3,
                 log_events: false
               )
    end

    test "still enforces max_input_bytes" do
      input = String.duplicate("a", 11)

      assert {:error, "Input exceeds maximum size (10 bytes)"} =
               UniversalSanitizer.sanitize_and_validate(input,
                 mode: :plain_text,
                 max_input_bytes: 10,
                 log_events: false
               )
    end

    test "still trims surrounding whitespace" do
      assert {:ok, "Luka <> Paul"} =
               UniversalSanitizer.sanitize_and_validate("  Luka <> Paul  ",
                 mode: :plain_text,
                 log_events: false
               )
    end

    test "accepts a percent-encoded sequence unchanged (no decoding, so no post-decode gate)" do
      # Plain-text mode never decodes, so the string that would be invalid
      # UTF-8 *after* decoding in strict mode is untouched and stays valid.
      assert {:ok, "Jos%E9 Smith"} =
               UniversalSanitizer.sanitize_and_validate("Jos%E9 Smith",
                 mode: :plain_text,
                 log_events: false
               )
    end

    test "does not URL-decode encoded sequences" do
      # Strict mode runs the input through URI.decode up to three times to
      # surface encoded malicious patterns. Plain-text mode skips that step
      # so a literal "%20" or "%3Cscript%3E" in a user-authored title is
      # preserved verbatim.
      assert {:ok, "Lunch %20 break"} =
               UniversalSanitizer.sanitize_and_validate("Lunch %20 break",
                 mode: :plain_text,
                 log_events: false
               )
    end

    test "ignores allow_html option when mode is :plain_text" do
      assert {:ok, "<b>hello</b>"} =
               UniversalSanitizer.sanitize_and_validate("<b>hello</b>",
                 mode: :plain_text,
                 allow_html: true,
                 log_events: false
               )
    end
  end

  # Captures Logger.warning calls with their metadata by attaching a temporary
  # :logger handler that forwards every log event to the test process. Returns
  # the list of captured events along with the text-level log output so
  # assertions can match on metadata (which Logger's default format does not
  # surface through `capture_log`).
  defp with_captured_warnings(fun) do
    test_pid = self()

    # :logger handler ids must be atoms. Each test invocation needs its own id
    # so async tests don't collide, hence the runtime atom creation. Safe here
    # because the test suite runs in a bounded process and the id set is tiny.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    handler_id = String.to_atom("captured_warnings_#{System.unique_integer([:positive])}")

    config = %{
      level: :warning,
      config: %{target: test_pid, tag: handler_id}
    }

    :ok = :logger.add_handler(handler_id, LoggerForwarder, config)

    try do
      log = capture_log(fun)
      events = collect_warnings(handler_id, [])
      {Enum.reverse(events), log}
    after
      :logger.remove_handler(handler_id)
    end
  end

  defp collect_warnings(handler_id, acc) do
    receive do
      {^handler_id, message, metadata} ->
        collect_warnings(handler_id, [%{message: message, metadata: metadata} | acc])
    after
      0 -> acc
    end
  end
end
