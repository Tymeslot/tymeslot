defmodule Tymeslot.Security.SecurityLoggerTest do
  @moduledoc false

  # async: false is required because these tests attach a global :logger handler
  # and lower the primary Logger level; running concurrently would leak both.
  use ExUnit.Case, async: false

  @moduletag :security

  alias Tymeslot.Infrastructure.Logging.MetadataRedactor
  alias Tymeslot.Security.SecurityLogger
  alias Tymeslot.Test.LogCapture

  # SecurityLogger emits at :info, while config/test.exs pins the primary level
  # to :warning. Lower it for the duration of the call and restore afterwards.
  #
  # MetadataRedactor is installed as a primary :logger filter and rewrites every
  # metadata key containing "session_id" to "[REDACTED]" before any handler sees
  # it. Lift it here so these tests observe what SecurityLogger itself emits;
  # that global belt-and-braces layer has its own tests.
  defp capture_security_logs(fun) do
    _previous = :logger.remove_primary_filter(:tymeslot_metadata_redactor)

    try do
      LogCapture.with_capture([logger_level: :info], fun)
    after
      MetadataRedactor.attach()
    end
  end

  describe "email masking via log_authentication_attempt/4" do
    # mask_email/1 is a private helper; its contract is verified here through the
    # public entry point by asserting on the :email_masked metadata key that
    # reaches Logger, and that no raw address reaches it under any key.

    test "masks the local part and keeps the domain" do
      capture_security_logs(fn ->
        SecurityLogger.log_authentication_attempt(
          "alice@example.com",
          false,
          "bad_password",
          %{ip_address: "203.0.113.1"}
        )
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "authentication_failure"} = meta}}
      assert meta.email_masked == "a***@example.com"
      assert meta.ip_address == "203.0.113.1"
    end

    test "trims and downcases before masking" do
      capture_security_logs(fn ->
        SecurityLogger.log_authentication_attempt(
          " Alice@Example.COM ",
          false,
          "bad_password",
          %{}
        )
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "authentication_failure"} = meta}}
      assert meta.email_masked == "a***@example.com"
    end

    test "drops a nil email rather than logging a placeholder" do
      capture_security_logs(fn ->
        SecurityLogger.log_authentication_attempt(nil, false, "missing_email", %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "authentication_failure"} = meta}}
      assert meta.email_masked == nil
    end

    test "drops a malformed email (no @ sign) entirely" do
      capture_security_logs(fn ->
        SecurityLogger.log_authentication_attempt("no-at-sign", false, "malformed", %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "authentication_failure"} = meta}}
      assert meta.email_masked == nil
      refute inspect(meta) =~ "no-at-sign"
    end

    test "masks a unicode local part without crashing" do
      capture_security_logs(fn ->
        SecurityLogger.log_authentication_attempt("漢字@example.com", false, "test", %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "authentication_failure"} = meta}}
      assert meta.email_masked == "漢***@example.com"
      refute inspect(meta) =~ "漢字@example.com"
    end
  end

  describe "log_authentication_attempt/4" do
    test "records the caller-supplied request context alongside the failure event" do
      capture_security_logs(fn ->
        SecurityLogger.log_authentication_attempt(
          "johndoe@example.com",
          false,
          "bad_password",
          %{ip_address: "203.0.113.1", user_agent: "curl/8.0"}
        )
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "authentication_failure"} = meta}}
      assert meta.email_masked == "j***@example.com"
      assert meta.ip_address == "203.0.113.1"
      assert meta.user_agent == "curl/8.0"
    end

    test "logs the success event type and leaves absent context nil" do
      # The third positional argument is `reason`, not metadata: it is recorded
      # in the event details but never reaches a Logger metadata key, so the
      # only observable difference a successful attempt makes is the event type.
      capture_security_logs(fn ->
        SecurityLogger.log_authentication_attempt("x@y.com", true, nil, %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "authentication_success"} = meta}}
      assert meta.email_masked == "x***@y.com"
      assert meta.ip_address == nil
      assert meta.user_agent == nil
    end
  end

  describe "log_security_event/2" do
    test "emits the event type with every detail key nil when details are sparse" do
      capture_security_logs(fn ->
        SecurityLogger.log_security_event("sparse_event", %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "sparse_event"} = meta}}
      assert meta.user_id == nil
      assert meta.email_masked == nil
      assert meta.ip_address == nil
      assert meta.user_agent == nil
      assert meta.session_id == nil
    end

    test "forwards every supplied detail as structured metadata" do
      capture_security_logs(fn ->
        SecurityLogger.log_security_event("full_event", %{
          user_id: 1,
          ip_address: "1.2.3.4",
          user_agent: "test",
          session_id: "abcdef12345678",
          email: "c@d.com"
        })
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "full_event"} = meta}}
      assert meta.user_id == 1
      assert meta.ip_address == "1.2.3.4"
      assert meta.user_agent == "test"
      assert meta.session_id == "abcdef12345678"
      assert meta.email_masked == "c***@d.com"
    end

    test "the raw email never reaches Logger under any key" do
      raw = "alice@example.com"

      capture_security_logs(fn ->
        SecurityLogger.log_security_event("test_event", %{email: raw})
      end)

      assert_receive {:captured_log, %{msg: {:string, message}, meta: meta}}
      assert IO.iodata_to_binary(message) == "Security event"
      assert meta.email_masked == "a***@example.com"
      refute inspect(meta) =~ raw
    end

    test "a mixed-case raw email never reaches Logger under any key" do
      capture_security_logs(fn ->
        SecurityLogger.log_security_event("test_event", %{email: " Alice@Example.COM "})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "test_event"} = meta}}
      assert meta.email_masked == "a***@example.com"
      refute inspect(meta) =~ "Alice@Example.COM"
      refute inspect(meta) =~ "alice@example.com"
    end

    test "forwards an identifier-shaped provider unchanged" do
      capture_security_logs(fn ->
        SecurityLogger.log_security_event("test_event", %{provider: "nextcloud"})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "test_event"} = meta}}
      assert meta.provider == "nextcloud"
    end

    test "drops a provider carrying unvalidated user input rather than logging it verbatim" do
      malicious = "<script>alert(1)</script>\nX-Injected: true"

      capture_security_logs(fn ->
        SecurityLogger.log_security_event("test_event", %{provider: malicious})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "test_event"} = meta}}
      assert meta.provider == nil
      refute inspect(meta) =~ malicious
    end

    test "drops an over-long provider value" do
      capture_security_logs(fn ->
        SecurityLogger.log_security_event("test_event", %{provider: String.duplicate("a", 33)})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "test_event"} = meta}}
      assert meta.provider == nil
    end
  end

  describe "log_blocked_input/3" do
    test "logs the field, the check that fired and the sanitised context" do
      capture_security_logs(fn ->
        SecurityLogger.log_blocked_input(:email, "sql_injection", %{
          ip: "1.2.3.4",
          user_id: 42,
          user_agent: "curl/8.0"
        })
      end)

      assert_receive {:captured_log,
                      %{level: :warning, msg: {:string, message}, meta: %{check: _check} = meta}}

      assert IO.iodata_to_binary(message) == "Suspicious input sanitised"
      assert meta.field == :email
      assert meta.check == "sql_injection"
      assert meta.ip_address == "1.2.3.4"
      assert meta.user_id == 42
      assert meta.user_agent == "curl/8.0"
    end

    test "accepts a string field name and drops context that fails validation" do
      capture_security_logs(fn ->
        SecurityLogger.log_blocked_input("email", "path_traversal", %{
          ip: "not-an-ip",
          user_id: "not-an-integer"
        })
      end)

      assert_receive {:captured_log, %{meta: %{check: "path_traversal"} = meta}}
      assert meta.field == "email"
      assert meta.ip_address == nil
      assert meta.user_id == nil
    end
  end

  describe "log_session_event/4" do
    test "redacts a long session id down to its last eight characters" do
      capture_security_logs(fn ->
        SecurityLogger.log_session_event(
          "created",
          1,
          "super_secret_session_token_abcdef12",
          %{}
        )
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "session_created"} = meta}}
      assert meta.user_id == 1
      assert meta.session_id == "…abcdef12"
      refute inspect(meta) =~ "super_secret_session_token"
    end

    test "replaces a session id shorter than eight characters outright" do
      capture_security_logs(fn ->
        SecurityLogger.log_session_event("created", 1, "short", %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "session_created"} = meta}}
      assert meta.session_id == "…REDACTED"
      refute inspect(meta) =~ "short"
    end

    test "tolerates a nil session id" do
      capture_security_logs(fn ->
        SecurityLogger.log_session_event("destroyed", 1, nil, %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "session_destroyed"} = meta}}
      assert meta.session_id == nil
    end
  end

  describe "log_account_lockout/3" do
    test "names the locked-out account as a masked email and records its kind" do
      capture_security_logs(fn ->
        SecurityLogger.log_account_lockout("alice@example.com", "locked", %{
          user_id: 7,
          ip_address: "203.0.113.9",
          user_agent: "curl/8.0"
        })
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "account_lockout"} = meta}}
      assert meta.email_masked == "a***@example.com"
      assert meta.lockout_type == "locked"
      assert meta.user_id == 7
      assert meta.ip_address == "203.0.113.9"
      assert meta.user_agent == "curl/8.0"
      refute inspect(meta) =~ "alice@example.com"
    end

    test "distinguishes a throttle from a lock" do
      capture_security_logs(fn ->
        SecurityLogger.log_account_lockout("bob@example.com", "throttled", %{})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "account_lockout"} = meta}}
      assert meta.lockout_type == "throttled"
      assert meta.user_id == nil
    end
  end

  describe "log_rate_limit_violation/3" do
    test "names an email identifier as a masked email, never raw" do
      capture_security_logs(fn ->
        SecurityLogger.log_rate_limit_violation("dave@example.com", "signup", %{
          ip_address: "203.0.113.9",
          user_agent: "curl/8.0"
        })
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "rate_limit_violation"} = meta}}
      assert meta.email_masked == "d***@example.com"
      assert meta.user_id == nil
      assert meta.limit_type == "signup"
      assert meta.ip_address == "203.0.113.9"
      assert meta.user_agent == "curl/8.0"
      refute inspect(meta) =~ "dave@example.com"
    end

    test "names an integer identifier as a user id, not an email" do
      capture_security_logs(fn ->
        SecurityLogger.log_rate_limit_violation(42, "email_verification", %{
          ip_address: "203.0.113.9"
        })
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "rate_limit_violation"} = meta}}
      assert meta.user_id == 42
      assert meta.email_masked == nil
      assert meta.limit_type == "email_verification"
    end
  end

  describe "log_social_auth_event/3" do
    test "records which provider the attempt was against" do
      capture_security_logs(fn ->
        SecurityLogger.log_social_auth_event("google", true, %{
          email: "carol@example.com",
          ip_address: "203.0.113.4"
        })
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "social_auth_success"} = meta}}
      assert meta.provider == "google"
      assert meta.email_masked == "c***@example.com"
      assert meta.ip_address == "203.0.113.4"
    end

    test "records the provider on a failure with no email available" do
      capture_security_logs(fn ->
        SecurityLogger.log_social_auth_event("github", false, %{ip_address: "203.0.113.5"})
      end)

      assert_receive {:captured_log, %{meta: %{event_type: "social_auth_failure"} = meta}}
      assert meta.provider == "github"
      assert meta.email_masked == nil
    end
  end
end
