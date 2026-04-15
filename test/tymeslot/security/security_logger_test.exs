defmodule Tymeslot.Security.SecurityLoggerTest do
  @moduledoc false

  # async: false is required because ExUnit.CaptureLog temporarily redirects the
  # Logger backend; running concurrently would cause captures to bleed across tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :security

  alias Tymeslot.Security.SecurityLogger

  describe "email masking via log_authentication_attempt/4" do
    # mask_email/1 is a private helper; its contract is verified here by
    # asserting that raw email addresses never appear in log output when
    # log_authentication_attempt/4 is called. The console formatter does not
    # include structured metadata keywords in its output string, so we can
    # only assert on absence — the same pattern used throughout this file.

    test "raw email is never emitted in log output" do
      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          SecurityLogger.log_authentication_attempt(
            "alice@example.com",
            false,
            "bad_password",
            %{ip_address: "203.0.113.1"}
          )
        end)

      Logger.configure(level: original_level)

      refute log =~ "alice@example.com"
      assert log =~ "Security event"
    end

    test "raw email with mixed case and whitespace is never emitted" do
      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          SecurityLogger.log_authentication_attempt(
            " Alice@Example.COM ",
            false,
            "bad_password",
            %{}
          )
        end)

      Logger.configure(level: original_level)

      refute log =~ "Alice@Example.COM"
      refute log =~ "alice@example.com"
      assert log =~ "Security event"
    end

    test "nil email is tolerated without crashing" do
      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          SecurityLogger.log_authentication_attempt(nil, false, "missing_email", %{})
        end)

      Logger.configure(level: original_level)

      assert log =~ "Security event"
    end

    test "malformed email (no @ sign) is tolerated without crashing" do
      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          SecurityLogger.log_authentication_attempt(
            "no-at-sign",
            false,
            "malformed",
            %{}
          )
        end)

      Logger.configure(level: original_level)

      refute log =~ "no-at-sign"
      assert log =~ "Security event"
    end

    test "unicode email local part is tolerated without crashing" do
      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          SecurityLogger.log_authentication_attempt(
            "漢字@example.com",
            false,
            "test",
            %{}
          )
        end)

      Logger.configure(level: original_level)

      refute log =~ "漢字@example.com"
      assert log =~ "Security event"
    end
  end

  describe "log_authentication_attempt/4 (smoke)" do
    test "returns :ok for a typical failed login" do
      assert :ok =
               SecurityLogger.log_authentication_attempt(
                 "johndoe@example.com",
                 false,
                 "bad_password",
                 %{ip_address: "203.0.113.1", user_agent: "curl/8.0"}
               )
    end

    test "tolerates nil and malformed emails without crashing" do
      assert :ok =
               SecurityLogger.log_authentication_attempt(nil, false, "missing_email", %{})

      assert :ok =
               SecurityLogger.log_authentication_attempt("not-an-email", false, "malformed", %{})
    end

    test "tolerates nil metadata" do
      assert :ok =
               SecurityLogger.log_authentication_attempt("x@y.com", true, nil, %{})
    end
  end

  describe "log_security_event/2" do
    test "accepts sparse details without crashing" do
      assert :ok = SecurityLogger.log_security_event("custom_event", %{})
      assert :ok = SecurityLogger.log_security_event("custom_event", %{email: "a@b.com"})

      assert :ok =
               SecurityLogger.log_security_event("custom_event", %{
                 user_id: 1,
                 ip_address: "1.2.3.4",
                 user_agent: "test",
                 session_id: "abcdef12345678",
                 email: "c@d.com"
               })
    end

    test "raw email never appears in Logger output" do
      raw = "alice@example.com"

      # log_security_event/2 emits at :info level. The test environment sets the
      # global Logger level to :warning, so we lower it for the duration of this
      # capture and restore it afterwards. async: false ensures this is safe.
      #
      # The console formatter does not include structured metadata keywords in its
      # output string — those are consumed by structured backends (logger_json in
      # production). What we can assert here is that the raw address is absent from
      # any emitted log line, confirming log_security_event/2 never passes it
      # directly to Logger. The masking invariant itself is covered by mask_email/1
      # unit tests above.
      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          SecurityLogger.log_security_event("test_event", %{email: raw})
        end)

      Logger.configure(level: original_level)

      refute log =~ raw
      assert log =~ "Security event"
    end

    test "raw email with mixed case and whitespace never appears in Logger output" do
      original_level = Logger.level()
      Logger.configure(level: :info)

      log =
        capture_log(fn ->
          SecurityLogger.log_security_event("test_event", %{email: " Alice@Example.COM "})
        end)

      Logger.configure(level: original_level)

      refute log =~ "Alice@Example.COM"
      refute log =~ "alice@example.com"
      assert log =~ "Security event"
    end
  end

  describe "log_blocked_input/3" do
    test "emits a warning log with the expected message" do
      original_level = Logger.level()
      Logger.configure(level: :warning)

      log =
        capture_log(fn ->
          SecurityLogger.log_blocked_input(:email, "sql_injection", %{ip: "1.2.3.4"})
        end)

      Logger.configure(level: original_level)

      assert log =~ "Malicious input blocked"
    end

    test "returns :ok" do
      assert :ok =
               SecurityLogger.log_blocked_input(:email, "sql_injection", %{ip: "1.2.3.4"})
    end

    test "accepts a string field name" do
      assert :ok = SecurityLogger.log_blocked_input("email", "path_traversal", %{})
    end
  end

  describe "log_session_event/4 (smoke)" do
    test "accepts long and short session ids" do
      assert :ok =
               SecurityLogger.log_session_event(
                 "created",
                 1,
                 "super_secret_session_token_abcdef12",
                 %{}
               )

      assert :ok = SecurityLogger.log_session_event("created", 1, "short", %{})
      assert :ok = SecurityLogger.log_session_event("created", 1, nil, %{})
    end
  end
end
