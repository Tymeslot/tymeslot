defmodule Tymeslot.Mailer.HealthCheck do
  @compile {:no_warn_undefined, :castore}

  @moduledoc """
  Health checks for mailer configuration at application startup.

  Validates that mailer configuration is correct and services are reachable
  before the application starts accepting requests. This prevents silent failures
  where emails fail hours or days after deployment.

  ## SMTP Validation

  1. **Structure Validation** (fast, always runs):
     - Required fields present (host, username, password)
     - Valid types and ranges
     - Non-empty values

  2. **Connection Test** (1-5 seconds, always runs):
     - Server is reachable on specified port
     - SMTP service responds with valid greeting (220)
     - SSL/TLS handshake succeeds (for port 465)
     - Certificate validation works

  **Not Tested:** SMTP authentication (credentials) - validated on first email send

  ## Postmark Validation

  1. **Structure Validation** (fast, always runs):
     - API key is present and non-empty
     - API key is a string

  2. **API Key Test** (1-5 seconds, always runs):
     - Makes request to Postmark `/server` endpoint
     - Validates API key is active and valid
     - Checks network connectivity to Postmark API

  ## Other Adapters

  - **Test/Local adapters**: No validation (assumed safe for development)
  - **Unknown adapters**: Warning logged, no validation

  ## Example

      config = Application.get_env(:tymeslot, Tymeslot.Mailer)
      Tymeslot.Mailer.HealthCheck.validate_startup_config!(config)
  """

  require Logger

  @type mailer_config :: keyword()

  @doc """
  Validates mailer configuration at startup.

  For SMTP adapter, performs both structure validation and connection test.
  For other adapters (Test, Local, Postmark), only validates they are configured.

  Logs errors prominently but always returns :ok to prevent blocking app startup.
  This allows the application to start even with email misconfiguration, but
  operators will see prominent error messages in logs indicating emails will fail.

  Note: Function name does not use ! suffix because it never raises - it logs
  errors and returns :ok in all cases.
  """
  @spec validate_startup_config(mailer_config()) :: :ok
  def validate_startup_config(config) do
    case config[:adapter] do
      Swoosh.Adapters.SMTP ->
        with :ok <- validate_smtp_structure(config),
             :ok <- test_smtp_connection(config) do
          Logger.info("✓ SMTP mailer configuration validated successfully")
          :ok
        else
          {:error, reason} ->
            Logger.error("""
            ╔═══════════════════════════════════════════════════════════════════════════════╗
            ║                                                                               ║
            ║  ⚠️  EMAIL SYSTEM NOT VALIDATED - EMAILS WILL FAIL  ⚠️                        ║
            ║                                                                               ║
            ╚═══════════════════════════════════════════════════════════════════════════════╝

            ✗ SMTP configuration validation failed: #{reason}

            Please verify your SMTP environment variables:
            - SMTP_HOST: SMTP server hostname
            - SMTP_PORT: SMTP server port (default: 587)
            - SMTP_USERNAME: SMTP username
            - SMTP_PASSWORD: SMTP password

            To test SMTP manually, run:
              mix tymeslot_saas.test_email your-email@example.com

            Application will start but emails WILL FAIL until configuration is fixed.
            """)

            # Return :ok to allow app to start despite validation failure
            :ok
        end

      adapter when adapter in [Swoosh.Adapters.Test, Swoosh.Adapters.Local] ->
        Logger.info("Mailer configured with #{inspect(adapter)} (no validation needed)")
        :ok

      Swoosh.Adapters.Postmark ->
        case validate_postmark_config(config) do
          :ok ->
            Logger.info("✓ Postmark mailer configuration validated successfully")
            :ok

          {:error, reason} ->
            Logger.error("""
            ╔═══════════════════════════════════════════════════════════════════════════════╗
            ║                                                                               ║
            ║  ⚠️  EMAIL SYSTEM NOT VALIDATED - EMAILS WILL FAIL  ⚠️                        ║
            ║                                                                               ║
            ╚═══════════════════════════════════════════════════════════════════════════════╝

            ✗ Postmark configuration validation failed: #{reason}

            Application will start but emails WILL FAIL until configuration is fixed.
            """)

            # Return :ok to allow app to start
            :ok
        end

      nil ->
        Logger.error("""
        ╔═══════════════════════════════════════════════════════════════════════════════╗
        ║                                                                               ║
        ║  ⚠️  EMAIL SYSTEM NOT CONFIGURED - NO EMAILS WILL BE SENT  ⚠️                 ║
        ║                                                                               ║
        ╚═══════════════════════════════════════════════════════════════════════════════╝

        ✗ Mailer adapter not configured. Set EMAIL_ADAPTER environment variable.
        """)

        :ok

      adapter ->
        Logger.warning("Unknown mailer adapter: #{inspect(adapter)}, skipping validation")
        :ok
    end
  end

  # Validates Postmark configuration and tests API key
  defp validate_postmark_config(config) do
    with :ok <- validate_postmark_structure(config),
         :ok <- test_postmark_api_key(config) do
      :ok
    else
      {:error, reason} ->
        error_message = """
        Postmark configuration validation failed: #{reason}

        Please verify your Postmark configuration:
        - POSTMARK_API_KEY: Your Postmark server API token

        Get your API key from: https://account.postmarkapp.com/servers
        """

        {:error, error_message}
    end
  end

  # Validates Postmark configuration structure
  defp validate_postmark_structure(config) do
    api_key = config[:api_key]

    cond do
      is_nil(api_key) ->
        {:error, "Postmark API key is required (set POSTMARK_API_KEY environment variable)"}

      not is_binary(api_key) ->
        {:error, "Postmark API key must be a string"}

      String.trim(api_key) == "" ->
        {:error, "Postmark API key cannot be empty"}

      true ->
        :ok
    end
  end

  # Tests Postmark API key by fetching server details
  defp test_postmark_api_key(config) do
    # Check if Finch is available (it might not be started during early boot)
    case Process.whereis(Tymeslot.Finch) do
      nil ->
        Logger.warning(
          "Postmark API key validation skipped (Finch not started). " <>
            "Structure validated but cannot test API connectivity. " <>
            "API key will be validated on first email send."
        )

        :ok

      _pid ->
        do_test_postmark_api_key(config)
    end
  end

  defp do_test_postmark_api_key(config) do
    api_key = config[:api_key]
    Logger.info("Testing Postmark API key...")

    # Use Postmark's /server endpoint to validate API key
    # This doesn't send any emails, just checks if the key is valid
    url = "https://api.postmarkapp.com/server"

    headers = [
      {"Accept", "application/json"},
      {"X-Postmark-Server-Token", api_key}
    ]

    case Finch.request(Finch.build(:get, url, headers), Tymeslot.Finch, receive_timeout: 5_000) do
      {:ok, %{status: 200}} ->
        Logger.info("✓ Postmark API key validation passed")
        :ok

      {:ok, %{status: 401}} ->
        Logger.error("✗ Postmark API key validation failed: Invalid API key")
        {:error, "Invalid Postmark API key (401 Unauthorized)"}

      {:ok, %{status: 422, body: body}} ->
        Logger.error("✗ Postmark API key validation failed",
          status: 422,
          body: String.slice(body, 0, 200)
        )

        {:error, "Invalid Postmark API key format (422 Unprocessable Entity)"}

      {:ok, %{status: status}} ->
        Logger.error("✗ Postmark API validation failed", status: status)
        {:error, "Postmark API returned unexpected status: #{status}"}

      {:error, %{reason: :timeout}} ->
        Logger.error("✗ Postmark API validation timed out")
        {:error, "Timeout connecting to Postmark API (check network connectivity)"}

      {:error, reason} ->
        Logger.error("✗ Postmark API validation failed", reason: inspect(reason))
        {:error, "Cannot connect to Postmark API: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("✗ Postmark API validation exception", error: Exception.message(e))
      {:error, "Postmark API validation error: #{Exception.message(e)}"}
  end

  # Validates SMTP configuration structure
  defp validate_smtp_structure(config) do
    cond do
      is_nil(config[:relay]) or config[:relay] == "" ->
        {:error, "SMTP host (relay) is required and cannot be empty"}

      is_nil(config[:username]) or config[:username] == "" ->
        {:error, "SMTP username is required and cannot be empty"}

      is_nil(config[:password]) or config[:password] == "" ->
        {:error, "SMTP password is required and cannot be empty"}

      not is_integer(config[:port]) ->
        {:error, "SMTP port must be an integer"}

      config[:port] not in 1..65_535 ->
        {:error, "SMTP port must be between 1-65535, got: #{config[:port]}"}

      true ->
        :ok
    end
  end

  # Tests SMTP server connection without sending email
  defp test_smtp_connection(config) do
    host_string = config[:relay]
    host = String.to_charlist(host_string)
    port = config[:port]
    dns_timeout = 3_000
    connection_timeout = 5_000

    Logger.info("Testing SMTP connection to #{host_string}:#{port}...")

    # First, resolve DNS separately to provide better error messages
    with :ok <- test_dns_resolution(host, host_string, dns_timeout),
         :ok <- test_smtp_connectivity(host, port, connection_timeout, config) do
      Logger.info("✓ SMTP connection test passed")
      :ok
    else
      {:error, reason} ->
        Logger.error("✗ SMTP connection test failed",
          host: host_string,
          port: port,
          reason: inspect(reason)
        )

        {:error, format_connection_error(reason, host_string, port)}
    end
  end

  # Test DNS resolution separately
  defp test_dns_resolution(host, _host_string, timeout) do
    case :inet.getaddr(host, :inet, timeout) do
      {:ok, _ip} ->
        :ok

      {:error, :nxdomain} ->
        {:error, {:dns_failed, :nxdomain}}

      {:error, reason} ->
        {:error, {:dns_failed, reason}}
    end
  rescue
    e ->
      {:error, {:dns_failed, Exception.message(e)}}
  end

  # Test actual SMTP connectivity
  defp test_smtp_connectivity(host, port, timeout, config) do
    case port do
      465 -> test_ssl_connection(host, port, timeout, config)
      587 -> test_starttls_connection(host, port, timeout)
      _ -> test_plain_connection(host, port, timeout)
    end
  end

  # Port 587: Plain connection with STARTTLS
  defp test_starttls_connection(host, port, timeout) do
    case :gen_tcp.connect(host, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        result =
          with {:ok, greeting} <- :gen_tcp.recv(socket, 0, timeout),
               :ok <- validate_smtp_greeting(greeting) do
            # Send QUIT to close cleanly
            :gen_tcp.send(socket, "QUIT\r\n")

            # Wait for 221 response (server closing connection)
            case :gen_tcp.recv(socket, 0, 1000) do
              {:ok, response} ->
                if String.starts_with?(response, "221") do
                  :ok
                else
                  # Server responded but not with expected close message
                  Logger.debug("Unexpected QUIT response: #{String.slice(response, 0, 50)}")
                  :ok
                end

              {:error, _} ->
                # Timeout or connection closed - acceptable, server might close immediately
                :ok
            end
          end

        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Port 465: Direct SSL connection
  defp test_ssl_connection(host, port, timeout, config) do
    ssl_opts = [
      :binary,
      active: false,
      verify: :verify_peer,
      cacerts: config[:tls_options][:cacerts] || load_fallback_cacerts(),
      server_name_indication: host,
      versions: config[:tls_options][:versions] || [:"tlsv1.2", :"tlsv1.3"],
      depth: config[:tls_options][:depth] || 5
    ]

    case :ssl.connect(host, port, ssl_opts, timeout) do
      {:ok, socket} ->
        result =
          with {:ok, greeting} <- :ssl.recv(socket, 0, timeout),
               :ok <- validate_smtp_greeting(greeting) do
            :ssl.send(socket, "QUIT\r\n")

            # Wait for 221 response (server closing connection)
            case :ssl.recv(socket, 0, 1000) do
              {:ok, response} ->
                if String.starts_with?(response, "221") do
                  :ok
                else
                  Logger.debug("Unexpected QUIT response: #{String.slice(response, 0, 50)}")
                  :ok
                end

              {:error, _} ->
                # Timeout or connection closed - acceptable
                :ok
            end
          end

        :ssl.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Load fallback cacerts if not provided in config
  defp load_fallback_cacerts do
    if Code.ensure_loaded?(:castore) do
      :castore.cacerts()
    else
      # This should not happen if dependencies are correct, but provide clear error
      raise "Cannot load CA certificates: castore module not available"
    end
  end

  # Other ports: Try plain connection
  defp test_plain_connection(host, port, timeout) do
    test_starttls_connection(host, port, timeout)
  end

  # Validates SMTP greeting message (should start with "220" and contain SMTP/ESMTP)
  defp validate_smtp_greeting(greeting) when is_binary(greeting) do
    cond do
      not String.starts_with?(greeting, "220") ->
        {:error, "Invalid SMTP greeting (expected 220 code): #{String.slice(greeting, 0, 100)}"}

      String.contains?(greeting, ["SMTP", "ESMTP", "smtp", "esmtp"]) ->
        :ok

      true ->
        # Greeting starts with 220 but doesn't mention SMTP
        # Log warning but accept (some servers have non-standard greetings)
        Logger.debug(
          "SMTP greeting starts with 220 but doesn't mention SMTP/ESMTP: " <>
            String.slice(greeting, 0, 100)
        )

        :ok
    end
  end

  # Formats connection error with helpful context and human-readable messages
  defp format_connection_error(reason, host, port) do
    readable_reason = format_readable_reason(reason)
    base_error = "Cannot connect to #{host}:#{port}: #{readable_reason}"
    suggestion = get_error_suggestion(reason, port)
    "#{base_error}#{suggestion}"
  end

  # Translates Erlang error atoms to human-readable messages
  defp format_readable_reason(:econnrefused), do: "Connection refused"

  defp format_readable_reason({:dns_failed, :nxdomain}),
    do: "Hostname not found (DNS resolution failed)"

  defp format_readable_reason({:dns_failed, reason}),
    do: "DNS resolution failed: #{inspect(reason)}"

  defp format_readable_reason(:timeout), do: "Connection timed out"
  defp format_readable_reason(:etimedout), do: "Connection timed out"

  defp format_readable_reason({:tls_alert, {:handshake_failure, _}}),
    do: "SSL/TLS handshake failed"

  defp format_readable_reason({:tls_alert, alert}), do: "SSL/TLS alert: #{inspect(alert)}"
  defp format_readable_reason(:closed), do: "Connection closed by server"
  defp format_readable_reason(reason), do: inspect(reason)

  # Provides helpful suggestions based on error type and port
  defp get_error_suggestion(:econnrefused, 587) do
    "\n\nPort 587 (STARTTLS) connection refused. Common causes:\n" <>
      "  - SMTP server is not running\n" <>
      "  - Firewall blocking port 587\n" <>
      "  - Wrong SMTP_HOST value\n" <>
      "  - Try port 465 (SSL) instead: SMTP_PORT=465"
  end

  defp get_error_suggestion(:econnrefused, 465) do
    "\n\nPort 465 (SSL) connection refused. Common causes:\n" <>
      "  - SMTP server is not running\n" <>
      "  - Firewall blocking port 465\n" <>
      "  - Wrong SMTP_HOST value\n" <>
      "  - Try port 587 (STARTTLS) instead: SMTP_PORT=587"
  end

  defp get_error_suggestion(reason, _) when reason in [:timeout, :etimedout] do
    "\n\nConnection timed out. Common causes:\n" <>
      "  - Firewall blocking outbound SMTP\n" <>
      "  - Network connectivity issues\n" <>
      "  - SMTP server is slow to respond"
  end

  defp get_error_suggestion({:dns_failed, :nxdomain}, _) do
    "\n\nHostname not found (DNS resolution failed).\n" <>
      "  - Verify SMTP_HOST is correct (no spaces, correct domain)\n" <>
      "  - Check DNS configuration"
  end

  defp get_error_suggestion({:tls_alert, {:handshake_failure, _}}, 465) do
    "\n\nSSL/TLS handshake failed. Common causes:\n" <>
      "  - Certificate verification failed\n" <>
      "  - Server requires different TLS version\n" <>
      "  - Server doesn't support port 465 SSL\n" <>
      "  - Try port 587 (STARTTLS) instead: SMTP_PORT=587"
  end

  defp get_error_suggestion(_, _), do: ""
end
