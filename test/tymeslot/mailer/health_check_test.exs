defmodule Tymeslot.Mailer.HealthCheckTest do
  use ExUnit.Case, async: true
  @moduletag :mailer

  alias Tymeslot.Mailer.HealthCheck

  describe "validate_startup_config/1 for SMTP" do
    test "validates complete and valid SMTP configuration" do
      # Use empty list for cacerts in test (since :castore module may not be loaded)
      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 587,
        username: "user@example.com",
        password: "secret123",
        ssl: false,
        tls: :always,
        tls_options: [
          versions: [:"tlsv1.2", :"tlsv1.3"],
          verify: :verify_peer,
          cacerts: [],
          server_name_indication: ~c"smtp.example.com",
          depth: 5
        ]
      ]

      # Structure validation passes, but connection test will fail
      # (which is expected in test environment without real SMTP server)
      # However, validate_startup_config now logs errors instead of raising
      assert :ok = HealthCheck.validate_startup_config(config)
    end

    test "logs error but returns :ok when SMTP host (relay) is missing" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: nil,
        port: 587,
        username: "user",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP host"
      assert log =~ "is required"
    end

    test "logs error but returns :ok when SMTP host is empty string" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "",
        port: 587,
        username: "user",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP host"
      assert log =~ "cannot be empty"
    end

    test "logs error but returns :ok when SMTP username is missing" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 587,
        username: nil,
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP username"
      assert log =~ "is required"
    end

    test "logs error but returns :ok when SMTP username is empty string" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 587,
        username: "",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP username"
      assert log =~ "cannot be empty"
    end

    test "logs error but returns :ok when SMTP password is missing" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 587,
        username: "user",
        password: nil
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP password"
      assert log =~ "is required"
    end

    test "logs error but returns :ok when SMTP password is empty string" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 587,
        username: "user",
        password: ""
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP password"
      assert log =~ "cannot be empty"
    end

    test "logs error but returns :ok when SMTP port is not an integer" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: "not_an_int",
        username: "user",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP port must be an integer"
    end

    test "logs error but returns :ok when SMTP port is out of valid range (too low)" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 0,
        username: "user",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP port must be between 1-65535"
    end

    test "logs error but returns :ok when SMTP port is out of valid range (too high)" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 99_999,
        username: "user",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP port must be between 1-65535"
    end
  end

  describe "validate_startup_config/1 for other adapters" do
    test "passes validation for Test adapter" do
      config = [adapter: Swoosh.Adapters.Test]

      assert :ok = HealthCheck.validate_startup_config(config)
    end

    test "passes validation for Local adapter" do
      config = [adapter: Swoosh.Adapters.Local]

      assert :ok = HealthCheck.validate_startup_config(config)
    end

    test "logs error but returns :ok when adapter is not configured" do
      import ExUnit.CaptureLog

      config = [adapter: nil]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Mailer adapter not configured"
    end
  end

  describe "validate_startup_config/1 for Postmark" do
    test "logs error but returns :ok when Postmark API key is missing" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: nil
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark API key is required"
    end

    test "logs error but returns :ok when Postmark API key is empty string" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: ""
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark API key cannot be empty"
    end

    test "logs error but returns :ok when Postmark API key is whitespace only" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: "   "
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark API key cannot be empty"
    end

    test "logs error but returns :ok when Postmark API key is not a string" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: :not_a_string
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark API key must be a string"
    end

    @tag :external
    test "validates API key with real Postmark API call" do
      import ExUnit.CaptureLog

      # This test requires a real Postmark API key and network access
      # Skip in normal test runs
      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: "invalid-test-key"
      ]

      # Should log error due to invalid API key (401) or timeout, but return :ok
      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Invalid Postmark API key" or log =~ "Postmark API validation timed out"
    end
  end

  describe "connection testing (structure validation only)" do
    # Note: Full connection tests would require real SMTP server or mocking
    # These tests only verify that the validation logic correctly identifies structure issues

    test "structure validation catches all required field issues" do
      import ExUnit.CaptureLog

      # Missing all fields
      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: nil,
        port: nil,
        username: nil,
        password: nil
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      # Should log error about missing fields
      assert log =~ "SMTP"
    end
  end

  describe "error message quality" do
    test "provides helpful error message for missing SMTP host" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: nil,
        port: 587,
        username: "user",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "SMTP_HOST"
      assert log =~ "environment variable"
    end

    test "provides helpful error message for missing credentials" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: "smtp.example.com",
        port: 587,
        username: nil,
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      # Just check that SMTP variables are mentioned
      assert log =~ "SMTP_USERNAME" or log =~ "SMTP username"
    end

    test "error message includes manual testing instructions" do
      import ExUnit.CaptureLog

      config = [
        adapter: Swoosh.Adapters.SMTP,
        relay: nil,
        port: 587,
        username: "user",
        password: "pass"
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "mix tymeslot_saas.test_email"
    end
  end
end
