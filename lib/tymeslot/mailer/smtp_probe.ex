defmodule Tymeslot.Mailer.SmtpProbe do
  @moduledoc """
  SMTP server reachability probe used during mailer health checks.

  Resolves the configured host's DNS, opens a connection appropriate for the
  port (plain TCP, STARTTLS, or direct SSL), and validates the SMTP greeting
  (220 response code). Closes the socket cleanly with QUIT. Returns
  human-readable error messages with port-specific troubleshooting hints
  when the probe fails.

  This probe never sends an email and never authenticates — credentials are
  only validated on the first real send.
  """

  @compile {:no_warn_undefined, CAStore}

  require Logger

  @dns_timeout_ms 3_000
  @connection_timeout_ms 5_000

  @doc """
  Tests SMTP server connectivity. Returns `:ok` on success or
  `{:error, message}` with a human-readable, actionable message.
  """
  @spec test_connection(keyword()) :: :ok | {:error, String.t()}
  def test_connection(config) do
    host_string = config[:relay]
    host = String.to_charlist(host_string)
    port = config[:port]

    Logger.info("Testing SMTP connection", host: host_string, port: port)

    with :ok <- test_dns_resolution(host, @dns_timeout_ms),
         :ok <- test_smtp_connectivity(host, port, @connection_timeout_ms, config) do
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

  defp test_dns_resolution(host, timeout) do
    case :inet.getaddr(host, :inet, timeout) do
      {:ok, _ip} -> :ok
      {:error, :nxdomain} -> {:error, {:dns_failed, :nxdomain}}
      {:error, reason} -> {:error, {:dns_failed, reason}}
    end
  rescue
    e -> {:error, {:dns_failed, Exception.message(e)}}
  end

  defp test_smtp_connectivity(host, port, timeout, config) do
    case port do
      465 -> test_ssl_connection(host, port, timeout, config)
      587 -> test_starttls_connection(host, port, timeout)
      _other -> test_starttls_connection(host, port, timeout)
    end
  end

  # Port 587 (and other non-SSL ports): plain TCP connection, validate greeting.
  defp test_starttls_connection(host, port, timeout) do
    case :gen_tcp.connect(host, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        result = exchange_greeting(socket, :gen_tcp, timeout)
        :gen_tcp.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # Port 465: direct SSL connection.
  defp test_ssl_connection(host, port, timeout, config) do
    ssl_opts = ssl_options(host, config)

    case :ssl.connect(host, port, ssl_opts, timeout) do
      {:ok, socket} ->
        result = exchange_greeting(socket, :ssl, timeout)
        :ssl.close(socket)
        result

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp exchange_greeting(socket, mod, timeout) do
    with {:ok, greeting} <- mod.recv(socket, 0, timeout),
         :ok <- validate_smtp_greeting(greeting) do
      mod.send(socket, "QUIT\r\n")
      drain_quit(socket, mod)
      :ok
    end
  end

  defp drain_quit(socket, mod) do
    case mod.recv(socket, 0, 1000) do
      {:ok, response} -> log_unexpected_quit(response)
      {:error, _reason} -> :ok
    end
  end

  defp log_unexpected_quit(response) do
    if not String.starts_with?(response, "221") do
      Logger.debug("Unexpected QUIT response from SMTP server",
        response: String.slice(response, 0, 50)
      )
    end

    :ok
  end

  defp ssl_options(host, config) do
    tls = config[:tls_options] || []
    versions = tls[:versions] || [:"tlsv1.2", :"tlsv1.3"]
    depth = tls[:depth] || 5

    base = [
      :binary,
      active: false,
      verify: :verify_peer,
      server_name_indication: host,
      # RFC 6125 hostname matching, including wildcard certificates — mirrors the
      # send path in SMTPConfig so the probe accepts the same certs a real send does.
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      versions: versions,
      depth: depth
    ]

    case tls[:cacerts] do
      nil -> base ++ [cacertfile: load_fallback_cacertfile()]
      cacerts -> base ++ [cacerts: cacerts]
    end
  end

  defp load_fallback_cacertfile do
    if Code.ensure_loaded?(CAStore) do
      CAStore.file_path()
    else
      raise "Cannot load CA certificates: CAStore module not available"
    end
  end

  defp validate_smtp_greeting(greeting) when is_binary(greeting) do
    cond do
      not String.starts_with?(greeting, "220") ->
        {:error, "Invalid SMTP greeting (expected 220 code): #{String.slice(greeting, 0, 100)}"}

      String.contains?(greeting, ["SMTP", "ESMTP", "smtp", "esmtp"]) ->
        :ok

      true ->
        Logger.debug(
          "SMTP greeting starts with 220 but doesn't mention SMTP/ESMTP: " <>
            String.slice(greeting, 0, 100)
        )

        :ok
    end
  end

  defp format_connection_error(reason, host, port) do
    readable_reason = format_readable_reason(reason)
    base_error = "Cannot connect to #{host}:#{port}: #{readable_reason}"
    suggestion = get_error_suggestion(reason, port)
    "#{base_error}#{suggestion}"
  end

  defp format_readable_reason(:econnrefused), do: "Connection refused"

  defp format_readable_reason({:dns_failed, :nxdomain}),
    do: "Hostname not found (DNS resolution failed)"

  defp format_readable_reason({:dns_failed, reason}),
    do: "DNS resolution failed: #{inspect(reason)}"

  defp format_readable_reason(:timeout), do: "Connection timed out"
  defp format_readable_reason(:etimedout), do: "Connection timed out"

  defp format_readable_reason({:tls_alert, {:handshake_failure, _details}}),
    do: "SSL/TLS handshake failed"

  defp format_readable_reason({:tls_alert, alert}), do: "SSL/TLS alert: #{inspect(alert)}"
  defp format_readable_reason(:closed), do: "Connection closed by server"
  defp format_readable_reason(reason), do: inspect(reason)

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

  defp get_error_suggestion(reason, _port) when reason in [:timeout, :etimedout] do
    "\n\nConnection timed out. Common causes:\n" <>
      "  - Firewall blocking outbound SMTP\n" <>
      "  - Network connectivity issues\n" <>
      "  - SMTP server is slow to respond"
  end

  defp get_error_suggestion({:dns_failed, :nxdomain}, _port) do
    "\n\nHostname not found (DNS resolution failed).\n" <>
      "  - Verify SMTP_HOST is correct (no spaces, correct domain)\n" <>
      "  - Check DNS configuration"
  end

  defp get_error_suggestion({:tls_alert, {:handshake_failure, _details}}, 465) do
    "\n\nSSL/TLS handshake failed. Common causes:\n" <>
      "  - Certificate verification failed\n" <>
      "  - Server requires different TLS version\n" <>
      "  - Server doesn't support port 465 SSL\n" <>
      "  - Try port 587 (STARTTLS) instead: SMTP_PORT=587"
  end

  defp get_error_suggestion(_other_reason, _port), do: ""
end
