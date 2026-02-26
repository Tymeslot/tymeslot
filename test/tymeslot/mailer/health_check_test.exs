defmodule Tymeslot.Mailer.HealthCheckTest do
  use ExUnit.Case, async: true
  @moduletag :mailer

  import ExUnit.CaptureLog

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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP host is empty string" do
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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP username is missing" do
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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP username is empty string" do
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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP password is missing" do
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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP password is empty string" do
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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP port is not an integer" do
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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP port is out of valid range (too low)" do
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

      assert log =~ "SMTP configuration validation failed"
    end

    test "logs error but returns :ok when SMTP port is out of valid range (too high)" do
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

      assert log =~ "SMTP configuration validation failed"
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
      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: nil
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark configuration validation failed"
    end

    test "logs error but returns :ok when Postmark API key is empty string" do
      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: ""
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark configuration validation failed"
    end

    test "logs error but returns :ok when Postmark API key is whitespace only" do
      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: "   "
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark configuration validation failed"
    end

    test "logs error but returns :ok when Postmark API key is not a string" do
      config = [
        adapter: Swoosh.Adapters.Postmark,
        api_key: :not_a_string
      ]

      log =
        capture_log([level: :error], fn ->
          assert :ok = HealthCheck.validate_startup_config(config)
        end)

      assert log =~ "Postmark configuration validation failed"
    end

    @tag :external
    test "validates API key with real Postmark API call" do
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

      assert log =~ "Postmark configuration validation failed"
    end
  end

  describe "connection testing (structure validation only)" do
    # Note: Full connection tests would require real SMTP server or mocking
    # These tests only verify that the validation logic correctly identifies structure issues

    test "structure validation catches all required field issues" do
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

      assert log =~ "SMTP configuration validation failed"
    end
  end
end
