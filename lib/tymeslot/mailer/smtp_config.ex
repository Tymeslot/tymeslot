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

  On port 465 the TLS options are additionally passed as `:sockopts`. gen_smtp
  reads `:tls_options` only when upgrading an existing connection with
  STARTTLS; on the implicit-TLS path it forwards `:sockopts` into
  `:ssl.connect/4` and ignores `:tls_options` entirely. Without this every
  port-465 send fails before the certificate is even examined, with
  `{:options, :incompatible, [verify: :verify_peer, cacerts: :undefined]}`.

  ## Certificate Verification

  Uses OTP 26+ `:public_key.cacerts_get()` to read OS certificate store,
  with automatic fallback to bundled `:castore` certificates for minimal
  Docker containers where the OS cert store may be empty.

  Two options cover servers a public trust store cannot validate, which is
  the common case for a self-hosted relay:

    * `:cacertfile` — a PEM bundle to trust instead of the public store, for
      a relay whose certificate is issued by a private CA.
    * `:tls_verify` — `:none` disables certificate verification entirely.
      This removes the protection against an intercepted connection, so it
      is a last resort for a self-signed relay; prefer `:cacertfile`.

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

  @typedoc """
  How far to trust the relay's certificate: `:peer` verifies it against the
  trust store (the default), `:none` accepts any certificate.
  """
  @type tls_verify :: :peer | :none

  @type smtp_opts :: [
          host: String.t(),
          port: pos_integer(),
          username: String.t(),
          password: String.t(),
          tls_verify: tls_verify(),
          cacertfile: String.t() | nil
        ]

  @type smtp_config :: keyword()

  @doc """
  Builds SMTP adapter configuration from provided options.

  ## Options

  - `:host` (required) - SMTP server hostname
  - `:port` (optional) - SMTP port (default: 587)
  - `:username` (required) - SMTP username
  - `:password` (required) - SMTP password
  - `:tls_verify` (optional) - `:peer` (default) or `:none`
  - `:cacertfile` (optional) - path to a PEM bundle to trust instead of the
    public certificate store

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
    tls_options = build_tls_options(smtp_host, opts)

    config =
      [
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
      ] ++ implicit_tls_sockopts(use_ssl, tls_options)

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
  defp determine_tls_mode(_arg), do: {false, :if_available}

  # gen_smtp reads `:tls_options` only in its STARTTLS upgrade path. On the
  # implicit-TLS path (`ssl: true`) it builds the socket options from
  # `:sockopts` alone and hands them straight to `:ssl.connect/4`, so without
  # this every port-465 send fails on OTP's default `verify: :verify_peer`
  # with no CA certificates. The plain-TCP path must not receive them: they
  # are not valid `:gen_tcp` options.
  defp implicit_tls_sockopts(true, tls_options), do: [sockopts: tls_options]
  defp implicit_tls_sockopts(false, _tls_options), do: []

  # Loads CA certificates with fallback to castore
  defp load_cacerts do
    certs =
      case :public_key.cacerts_get() do
        [] ->
          # Fallback to castore bundled certificates for minimal containers
          Logger.debug("Using castore bundled CA certificates (OS cert store empty)")
          load_castore_certs()

        [_first_cert | _rest] = certs ->
          Logger.debug("Using OS certificate store", cert_count: length(certs))
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
      |> Enum.map(fn {:Certificate, der, _encoding} -> der end)
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
  defp build_tls_options(smtp_host, opts) do
    base = [
      # Modern TLS versions only (TLS 1.2 and 1.3)
      versions: [:"tlsv1.2", :"tlsv1.3"],
      # Server Name Indication for hostname verification (prevents MITM)
      server_name_indication: String.to_charlist(smtp_host),
      # Maximum certificate chain depth: root CA + up to 3 intermediates + server cert
      # Industry standard allows 3-5 levels; 5 provides good compatibility
      depth: 5
    ]

    base ++
      verify_options(
        validate_tls_verify!(opts[:tls_verify]),
        validate_cacertfile!(opts[:cacertfile])
      )
  end

  # Verification disabled: no trust store is consulted, and none is required.
  # Demanding one here would defeat the point for the operator who turned
  # verification off precisely because they have no usable CA bundle.
  defp verify_options(:none, _cacertfile) do
    Logger.warning(
      "SMTP certificate verification is DISABLED (SMTP_TLS_VERIFY=none). The connection " <>
        "is encrypted but the relay's identity is not checked, so an intercepted " <>
        "connection cannot be detected. Prefer SMTP_CACERTFILE with your relay's CA."
    )

    [verify: :verify_none]
  end

  defp verify_options(:peer, cacertfile) do
    [verify: :verify_peer] ++
      trust_store(cacertfile) ++ [customize_hostname_check: hostname_check()]
  end

  # A private CA replaces the public store rather than extending it: a relay
  # whose certificate chains to an internal CA has no reason to also be
  # accepted under a public root.
  defp trust_store(nil), do: [cacerts: load_cacerts()]
  defp trust_store(cacertfile), do: [cacertfile: cacertfile]

  # RFC 6125 hostname matching, including wildcard certificates. Without this,
  # OTP's default matcher rejects a wildcard cert (e.g. `*.mailbox.org`) when
  # connecting to a subdomain host (e.g. `smtp.mailbox.org`) with a fatal
  # `{:bad_cert, {:hostname_check_failed, ...}}` alert. This is the same
  # matcher Mint/Finch/Req use for HTTPS.
  defp hostname_check do
    [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
  end

  defp validate_tls_verify!(nil), do: :peer
  defp validate_tls_verify!(mode) when mode in [:peer, :none], do: mode

  defp validate_tls_verify!(mode) do
    raise ArgumentError, "SMTP TLS verify must be :peer or :none, got: #{inspect(mode)}"
  end

  defp validate_cacertfile!(nil), do: nil

  defp validate_cacertfile!(path) when is_binary(path) do
    trimmed = String.trim(path)

    if File.regular?(trimmed) do
      trimmed
    else
      raise ArgumentError,
            "SMTP CA certificate file not found or not readable: #{inspect(trimmed)} " <>
              "(SMTP_CACERTFILE must point at a PEM bundle inside the container)"
    end
  end

  defp validate_cacertfile!(path) do
    raise ArgumentError, "SMTP CA certificate file must be a string, got: #{inspect(path)}"
  end

  # Logs SMTP configuration at startup (without password)
  defp log_config(config) do
    {ssl_mode, tls_mode} =
      case {config[:ssl], config[:tls]} do
        {true, :never} -> {"SSL (port 465)", "disabled"}
        {false, :always} -> {"no", "STARTTLS (required)"}
        {false, :if_available} -> {"no", "opportunistic"}
        _config_values -> {"unknown", "unknown"}
      end

    # Log at info level so operators can see SMTP configuration in production
    Logger.info("SMTP mailer configured",
      host: config[:relay],
      port: config[:port],
      username: config[:username],
      ssl: ssl_mode,
      tls: tls_mode,
      verify: config[:tls_options][:verify],
      timeout: config[:timeout],
      retries: config[:retries]
    )
  end
end
