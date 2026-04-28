defmodule Tymeslot.Mailer.HealthCheck do
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

  2. **Connection Test** (1-5 seconds, always runs) — see `Tymeslot.Mailer.SmtpProbe`:
     - Server is reachable on specified port
     - SMTP service responds with valid greeting (220)
     - SSL/TLS handshake succeeds (for port 465)
     - Certificate validation works

  **Not Tested:** SMTP authentication (credentials) - validated on first email send

  ## Postmark Validation

  1. **Structure Validation** (fast, always runs):
     - API key is present and non-empty
     - API key is a string

  2. **API Key Test** (1-5 seconds, always runs) — see `Tymeslot.Mailer.PostmarkProbe`:
     - Makes request to Postmark `/server` endpoint
     - Validates API key is active and valid
     - Checks network connectivity to Postmark API

  ## Other Adapters

  - **Test/Local adapters**: No validation (assumed safe for development)
  - **Unknown adapters**: Warning logged, no validation

  ## Example

      config = Application.get_env(:tymeslot, Tymeslot.Mailer)
      Tymeslot.Mailer.HealthCheck.validate_startup_config(config)
  """

  require Logger

  alias Tymeslot.Mailer.{PostmarkProbe, SmtpProbe}

  @type mailer_config :: keyword()

  @doc """
  Validates mailer configuration at startup.

  For SMTP adapter, performs both structure validation and connection test.
  For Postmark adapter, performs structure validation and API key test.
  For Test/Local adapters, no validation is performed.

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
        validate_smtp(config)

      Swoosh.Adapters.Postmark ->
        validate_postmark(config)

      adapter when adapter in [Swoosh.Adapters.Test, Swoosh.Adapters.Local] ->
        log_dev_adapter(adapter)

      nil ->
        log_missing_adapter()

      adapter ->
        log_unknown_adapter(adapter)
    end
  end

  defp validate_smtp(config) do
    with :ok <- validate_smtp_structure(config),
         :ok <- SmtpProbe.test_connection(config) do
      Logger.info("✓ SMTP mailer configuration validated successfully")
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "SMTP configuration validation failed; emails will not be sent until configuration is fixed",
          reason: reason
        )

        :ok
    end
  end

  defp validate_postmark(config) do
    with :ok <- validate_postmark_structure(config),
         :ok <- PostmarkProbe.test_api_key(config) do
      Logger.info("✓ Postmark mailer configuration validated successfully")
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "Postmark configuration validation failed; verify POSTMARK_API_KEY at https://account.postmarkapp.com/servers",
          reason: reason
        )

        :ok
    end
  end

  defp log_dev_adapter(adapter) do
    Logger.info("Mailer configured with dev/test adapter; no validation needed",
      adapter: inspect(adapter)
    )

    :ok
  end

  defp log_missing_adapter do
    Logger.error(
      "Mailer adapter not configured; no emails will be sent. Set the EMAIL_ADAPTER environment variable."
    )

    :ok
  end

  defp log_unknown_adapter(adapter) do
    Logger.warning("Unknown mailer adapter; skipping validation", adapter: inspect(adapter))
    :ok
  end

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
end
