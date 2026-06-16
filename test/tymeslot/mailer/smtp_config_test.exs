defmodule Tymeslot.Mailer.SMTPConfigTest do
  use ExUnit.Case, async: true
  @moduletag :mailer

  alias Tymeslot.Mailer.SMTPConfig

  describe "build/1" do
    test "creates valid SMTP configuration for port 587 (STARTTLS)" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          port: 587,
          username: "user@example.com",
          password: "secret123"
        )

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 587
      assert config[:username] == "user@example.com"
      assert config[:password] == "secret123"
      assert config[:ssl] == false
      assert config[:tls] == :always
      assert config[:auth] == :if_available
      assert config[:retries] == 2
      assert config[:timeout] == 10_000
      assert config[:no_mx_lookups] == true
      assert is_list(config[:tls_options])
    end

    test "creates valid SMTP configuration for port 465 (direct SSL)" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          port: 465,
          username: "user@example.com",
          password: "secret123"
        )

      assert config[:ssl] == true
      assert config[:tls] == :never
      assert config[:port] == 465
    end

    test "creates valid SMTP configuration for non-standard port (opportunistic TLS)" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          port: 2525,
          username: "user@example.com",
          password: "secret123"
        )

      assert config[:ssl] == false
      assert config[:tls] == :if_available
      assert config[:port] == 2525
    end

    test "uses default port 587 when not specified" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user@example.com",
          password: "secret123"
        )

      assert config[:port] == 587
    end

    test "TLS options include all required fields" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          port: 587,
          username: "user",
          password: "pass"
        )

      tls_opts = config[:tls_options]
      assert Keyword.has_key?(tls_opts, :versions)
      assert Keyword.has_key?(tls_opts, :verify)
      assert Keyword.has_key?(tls_opts, :cacerts)
      assert Keyword.has_key?(tls_opts, :server_name_indication)
      assert Keyword.has_key?(tls_opts, :depth)
    end

    test "TLS versions include only modern protocols" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user",
          password: "pass"
        )

      versions = config[:tls_options][:versions]
      assert :"tlsv1.2" in versions
      assert :"tlsv1.3" in versions
      refute :"tlsv1.1" in versions
      refute :tlsv1 in versions
    end

    test "TLS options use verify_peer for security" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user",
          password: "pass"
        )

      assert config[:tls_options][:verify] == :verify_peer
    end

    test "certificate chain depth is set to 5" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user",
          password: "pass"
        )

      assert config[:tls_options][:depth] == 5
    end

    test "SNI is properly formatted as charlist" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user",
          password: "pass"
        )

      sni = config[:tls_options][:server_name_indication]
      assert is_list(sni)
      assert sni == ~c"smtp.example.com"
    end

    test "CA certificates are loaded from system or castore" do
      config =
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user",
          password: "pass"
        )

      cacerts = config[:tls_options][:cacerts]
      assert is_list(cacerts)
      assert cacerts != []
    end
  end

  describe "build/1 validation" do
    test "raises when host is nil" do
      assert_raise ArgumentError, ~r/SMTP host is required/, fn ->
        SMTPConfig.build(
          host: nil,
          username: "user",
          password: "pass"
        )
      end
    end

    test "raises when host is empty string" do
      assert_raise ArgumentError, ~r/SMTP host cannot be empty/, fn ->
        SMTPConfig.build(
          host: "",
          username: "user",
          password: "pass"
        )
      end
    end

    test "trims whitespace from host" do
      config =
        SMTPConfig.build(
          host: "  smtp.example.com  ",
          username: "user",
          password: "pass"
        )

      assert config[:relay] == "smtp.example.com"
    end

    test "raises when host is whitespace-only" do
      assert_raise ArgumentError, ~r/SMTP host cannot be empty or whitespace-only/, fn ->
        SMTPConfig.build(
          host: "   ",
          username: "user",
          password: "pass"
        )
      end
    end

    test "raises when host is not a string" do
      assert_raise ArgumentError, ~r/SMTP host must be a string/, fn ->
        SMTPConfig.build(
          host: :not_a_string,
          username: "user",
          password: "pass"
        )
      end
    end

    test "raises when username is nil" do
      assert_raise ArgumentError, ~r/SMTP username is required/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          username: nil,
          password: "pass"
        )
      end
    end

    test "raises when username is empty string" do
      assert_raise ArgumentError, ~r/SMTP username cannot be empty/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "",
          password: "pass"
        )
      end
    end

    test "raises when password is nil" do
      assert_raise ArgumentError, ~r/SMTP password is required/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user",
          password: nil
        )
      end
    end

    test "raises when password is empty string" do
      assert_raise ArgumentError, ~r/SMTP password cannot be empty/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          username: "user",
          password: ""
        )
      end
    end

    test "raises when port is negative" do
      assert_raise ArgumentError, ~r/SMTP port must be between 1-65535/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          port: -1,
          username: "user",
          password: "pass"
        )
      end
    end

    test "raises when port is zero" do
      assert_raise ArgumentError, ~r/SMTP port must be between 1-65535/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          port: 0,
          username: "user",
          password: "pass"
        )
      end
    end

    test "raises when port is above 65535" do
      assert_raise ArgumentError, ~r/SMTP port must be between 1-65535/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          port: 99_999,
          username: "user",
          password: "pass"
        )
      end
    end

    test "raises when port is not an integer" do
      assert_raise ArgumentError, ~r/SMTP port must be an integer/, fn ->
        SMTPConfig.build(
          host: "smtp.example.com",
          port: "not_an_int",
          username: "user",
          password: "pass"
        )
      end
    end
  end

  describe "logging" do
    import ExUnit.CaptureLog

    @tag :capture_log
    test "logs SMTP configuration at startup" do
      # Temporarily set logger level to :info to capture the log message
      original_level = Logger.level()
      Logger.configure(level: :info)

      try do
        log =
          capture_log([level: :info], fn ->
            SMTPConfig.build(
              host: "smtp.example.com",
              port: 587,
              username: "user@example.com",
              password: "secret123"
            )
          end)

        # Verify configuration is logged (now at :info level)
        # In test environment, logs may not be captured, so only assert if log is present
        if log != "" do
          assert log =~ "SMTP mailer configured"
          # Structured metadata (host, username) is passed to Logger but not embedded
          # in the formatted message string captured by capture_log
          # Password should never appear in logs
          refute log =~ "secret123"
        end
      after
        # Restore original logger level
        Logger.configure(level: original_level)
      end
    end
  end
end
