defmodule Tymeslot.Mailer.SMTPConfig do
  @compile {:no_warn_undefined, CAStore}

  @moduledoc """
  Builds SMTP configuration with proper SSL/TLS/STARTTLS settings for OTP 26+.

  This module centralizes SMTP configuration logic to ensure consistency across
  production, development, and testing environments.

  ## SSL/TLS Modes

  - **Port 465**: Direct SSL (implicit TLS) - `ssl: true, tls: :never`
  - **Port 587**: STARTTLS (explicit TLS) - `ssl: false, tls: :always`
  - **Other ports**: Opportunistic TLS - `ssl: false, tls: :if_available`

  ## Certificate Verification

  Uses OTP 26+ `:public_key.cacerts_get()` to read OS certificate store,
  with automatic fallback to bundled `:castore` certificates for minimal
  Docker containers where the OS cert store may be empty.

  ## Example

      config = Tymeslot.Mailer.SMTPConfig.build(
        host: "smtp.gmail.com",
        port: 587,
        username: "user@gmail.com",
        password: "app_password"
      )

      # Returns keyword list suitable for Swoosh.Adapters.SMTP
  """

  require Logger

  @type smtp_opts :: [
          host: String.t(),
          port: pos_integer(),
          username: String.t(),
          password: String.t()
        ]

  @type smtp_config :: keyword()

  @doc """
  Builds SMTP adapter configuration from provided options.

  ## Options

  - `:host` (required) - SMTP server hostname
  - `:port` (optional) - SMTP port (default: 587)
  - `:username` (required) - SMTP username
  - `:password` (required) - SMTP password

  ## Raises

  - `ArgumentError` if required options are missing or invalid
  """
  @spec build(smtp_opts()) :: smtp_config()
  def build(opts) do
    smtp_host = validate_host!(opts[:host])
    smtp_port = validate_port!(opts[:port] || 587)
    smtp_username = validate_username!(opts[:username])
    smtp_password = validate_password!(opts[:password])

    {use_ssl, tls_mode} = determine_tls_mode(smtp_port)
    cacerts = load_cacerts()
    tls_options = build_tls_options(smtp_host, cacerts)

    config = [
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_host,
      port: smtp_port,
      username: smtp_username,
      password: smtp_password,
      ssl: use_ssl,
      tls: tls_mode,
      tls_options: tls_options,
      auth: :if_available,
      # Retry failed sends twice (total 3 attempts: initial + 2 retries)
      retries: 2,
      # Connection timeout in milliseconds
      timeout: 10_000,
      # Direct relay to configured host, skip DNS MX lookup overhead
      no_mx_lookups: true
    ]

    log_config(config)
    config
  end

  # Validates SMTP host is present and non-empty
  defp validate_host!(nil) do
    raise ArgumentError, "SMTP host is required (set SMTP_HOST environment variable)"
  end

  defp validate_host!("") do
    raise ArgumentError, "SMTP host cannot be empty"
  end

  defp validate_host!(host) when is_binary(host) do
    # Trim whitespace to handle common configuration errors
    trimmed = String.trim(host)

    if trimmed == "" do
      raise ArgumentError, "SMTP host cannot be empty or whitespace-only"
    end

    trimmed
  end

  defp validate_host!(host) do
    raise ArgumentError, "SMTP host must be a string, got: #{inspect(host)}"
  end

  # Validates SMTP port is a valid integer in range 1-65535
  defp validate_port!(port) when is_integer(port) and port >= 1 and port <= 65_535 do
    port
  end

  defp validate_port!(port) when is_integer(port) do
    raise ArgumentError, "SMTP port must be between 1-65535, got: #{port}"
  end

  defp validate_port!(port) do
    raise ArgumentError, "SMTP port must be an integer, got: #{inspect(port)}"
  end

  # Validates SMTP username is present
  defp validate_username!(nil) do
    raise ArgumentError, "SMTP username is required (set SMTP_USERNAME environment variable)"
  end

  defp validate_username!("") do
    raise ArgumentError, "SMTP username cannot be empty"
  end

  defp validate_username!(username) when is_binary(username), do: username

  defp validate_username!(username) do
    raise ArgumentError, "SMTP username must be a string, got: #{inspect(username)}"
  end

  # Validates SMTP password is present
  defp validate_password!(nil) do
    raise ArgumentError, "SMTP password is required (set SMTP_PASSWORD environment variable)"
  end

  defp validate_password!("") do
    raise ArgumentError, "SMTP password cannot be empty"
  end

  defp validate_password!(password) when is_binary(password) do
    # Warn about potentially problematic characters in passwords
    if String.contains?(password, ["\"", "\\", "\r", "\n", "\t"]) do
      Logger.warning(
        "SMTP password contains special characters (quotes, backslashes, or newlines) " <>
          "that may cause authentication issues with some SMTP servers"
      )
    end

    password
  end

  defp validate_password!(password) do
    raise ArgumentError, "SMTP password must be a string, got: #{inspect(password)}"
  end

  # Determines SSL/TLS mode based on SMTP port
  defp determine_tls_mode(465), do: {true, :never}
  defp determine_tls_mode(587), do: {false, :always}
  defp determine_tls_mode(_), do: {false, :if_available}

  # Loads CA certificates with fallback to castore
  defp load_cacerts do
    certs =
      case :public_key.cacerts_get() do
        [] ->
          # Fallback to castore bundled certificates for minimal containers
          Logger.debug("Using castore bundled CA certificates (OS cert store empty)")
          load_castore_certs()

        [_ | _] = certs ->
          Logger.debug("Using OS certificate store (#{length(certs)} certificates)")
          certs
      end

    # Validate we have certificates and they're in correct format
    validate_cacerts!(certs)
  end

  # Loads castore certificates with safety check
  defp load_castore_certs do
    if Code.ensure_loaded?(CAStore) do
      # Get path to castore's CA bundle (PEM format)
      ca_bundle_path = CAStore.file_path()

      # Read and parse PEM file to extract DER-encoded certificates
      ca_bundle_path
      |> File.read!()
      |> :public_key.pem_decode()
      |> Enum.map(fn {:Certificate, der, _} -> der end)
    else
      raise """
      No CA certificates available:
      - OS certificate store is empty
      - CAStore module is not loaded (dependency missing?)

      Cannot verify SMTP SSL/TLS connections without CA certificates.
      """
    end
  end

  # Validates loaded certificates are valid
  defp validate_cacerts!(certs) do
    cond do
      not is_list(certs) ->
        raise "CA certificates must be a list, got: #{inspect(certs)}"

      Enum.empty?(certs) ->
        raise """
        No CA certificates available for SMTP SSL/TLS verification.

        This should not happen - both OS cert store and castore returned empty.
        Check that:
        1. castore dependency is properly installed
        2. OS certificate store is not corrupted
        """

      # OTP's :public_key.cacerts_get() returns DER-encoded certs which can be
      # either binary or tuples depending on OTP version. We just need to ensure
      # we have something that looks like certificate data.
      true ->
        certs
    end
  end

  # Builds TLS options for OTP 26+ certificate verification
  defp build_tls_options(smtp_host, cacerts) do
    [
      # Modern TLS versions only (TLS 1.2 and 1.3)
      versions: [:"tlsv1.2", :"tlsv1.3"],
      # Verify peer certificate (strict security)
      verify: :verify_peer,
      # CA certificates for chain validation
      cacerts: cacerts,
      # Server Name Indication for hostname verification (prevents MITM)
      server_name_indication: String.to_charlist(smtp_host),
      # Maximum certificate chain depth: root CA + up to 3 intermediates + server cert
      # Industry standard allows 3-5 levels; 5 provides good compatibility
      depth: 5
    ]
  end

  # Logs SMTP configuration at startup (without password)
  defp log_config(config) do
    {ssl_mode, tls_mode} =
      case {config[:ssl], config[:tls]} do
        {true, :never} -> {"SSL (port 465)", "disabled"}
        {false, :always} -> {"no", "STARTTLS (required)"}
        {false, :if_available} -> {"no", "opportunistic"}
        _ -> {"unknown", "unknown"}
      end

    # Log at info level so operators can see SMTP configuration in production
    Logger.info("SMTP mailer configured",
      host: config[:relay],
      port: config[:port],
      username: config[:username],
      ssl: ssl_mode,
      tls: tls_mode,
      timeout: config[:timeout],
      retries: config[:retries]
    )
  end
end
