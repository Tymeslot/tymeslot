defmodule Tymeslot.Mailer.CloudronConfig do
  @moduledoc """
  Builds Swoosh SMTP configuration from Cloudron's sendmail addon environment variables.

  Cloudron provides a local SMTP relay that does not use TLS/STARTTLS.
  This module reads `CLOUDRON_MAIL_SMTP_*` env vars and produces a config
  keyword list compatible with `Swoosh.Adapters.SMTP`.

  ## Cloudron Environment Variables

  - `CLOUDRON_MAIL_SMTP_SERVER` — relay hostname
  - `CLOUDRON_MAIL_SMTP_PORT` — relay port (no TLS)
  - `CLOUDRON_MAIL_SMTP_USERNAME` — authentication username
  - `CLOUDRON_MAIL_SMTP_PASSWORD` — authentication password
  - `CLOUDRON_MAIL_FROM` — sender address
  - `CLOUDRON_MAIL_DOMAIN` — sender domain
  """

  require Logger

  @doc """
  Builds SMTP adapter configuration from Cloudron sendmail addon options.

  ## Options

  - `:server` (required) — SMTP relay hostname
  - `:port` (optional) — SMTP port (string or nil, defaults to 25)
  - `:username` (required) — SMTP username
  - `:password` (required) — SMTP password
  """
  @spec build(keyword()) :: keyword()
  def build(opts) do
    server = validate_required!(opts[:server], "CLOUDRON_MAIL_SMTP_SERVER")
    username = validate_required!(opts[:username], "CLOUDRON_MAIL_SMTP_USERNAME")
    password = validate_required!(opts[:password], "CLOUDRON_MAIL_SMTP_PASSWORD")
    port = parse_port(opts[:port])

    config = [
      adapter: Swoosh.Adapters.SMTP,
      relay: server,
      port: port,
      username: username,
      password: password,
      ssl: false,
      tls: :never,
      auth: :always,
      retries: 2,
      timeout: 10_000,
      no_mx_lookups: true
    ]

    Logger.info("Cloudron sendmail addon configured",
      host: server,
      port: port,
      username: username
    )

    config
  end

  defp validate_required!(nil, var_name) do
    raise ArgumentError, "#{var_name} is required but not set"
  end

  defp validate_required!("", var_name) do
    raise ArgumentError, "#{var_name} is required but empty"
  end

  defp validate_required!(value, _) when is_binary(value), do: value

  defp parse_port(nil), do: 25
  defp parse_port(port) when is_integer(port), do: port

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {value, ""} -> value
      _ -> raise ArgumentError, "CLOUDRON_MAIL_SMTP_PORT must be a valid integer, got: #{inspect(port)}"
    end
  end
end
