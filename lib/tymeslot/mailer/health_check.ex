defmodule Tymeslot.Mailer.HealthCheck do
  @moduledoc """
  Health checks for mailer configuration at application startup.

  Validates that mailer configuration is correct and the provider is reachable
  before the application starts accepting requests. This prevents silent
  failures where emails fail hours or days after deployment.

  Which checks run is decided by `Tymeslot.Mailer.Providers`, so a provider
  added to that registry is validated here without touching this module.

  1. **Structure validation** (fast, always runs): every key the adapter
     requires is present, a string, and non-empty. SMTP additionally checks
     the port is an integer in range.

  2. **Credential test** (1-5 seconds, always runs): SMTP opens a connection
     via `Tymeslot.Mailer.SmtpProbe`; the API providers call one cheap
     endpoint via `Tymeslot.Mailer.ApiProbe`. Neither sends mail.

  **Not tested:** SMTP authentication, which is validated on first email send.

  ## Other adapters

  - **Test and Local adapters**: no validation, they are development targets.
  - **Adapters outside the registry**: warning logged, no validation.

  ## Example

      config = Application.get_env(:tymeslot, Tymeslot.Mailer)
      Tymeslot.Mailer.HealthCheck.validate_startup_config(config)
  """

  require Logger

  alias Tymeslot.Mailer.{ApiProbe, Providers, SmtpProbe}

  @type mailer_config :: keyword()

  @doc """
  Validates mailer configuration at startup.

  Logs errors prominently but always returns `:ok` to prevent blocking app
  startup. This allows the application to start even with email
  misconfiguration, but operators will see prominent error messages in logs
  indicating emails will fail.

  Note: function name does not use a `!` suffix because it never raises; it
  logs errors and returns `:ok` in all cases.
  """
  @spec validate_startup_config(mailer_config()) :: :ok
  def validate_startup_config(config) do
    case config[:adapter] do
      nil ->
        log_missing_adapter()

      adapter ->
        case Providers.for_adapter(adapter) do
          {:ok, entry} -> validate(entry, config)
          :error -> log_unknown_adapter(adapter)
        end
    end
  end

  defp validate(%{probe: :none} = entry, _config) do
    Logger.info("Mailer configured with a development adapter; no validation needed",
      provider: entry.label
    )

    :ok
  end

  defp validate(entry, config) do
    with :ok <- validate_structure(entry, config),
         :ok <- probe(entry, config) do
      Logger.info("✓ Mailer configuration validated successfully", provider: entry.label)
      :ok
    else
      {:error, reason} ->
        Logger.error(
          "Mailer configuration validation failed; emails will not be sent " <>
            "until the configuration is fixed",
          provider: entry.label,
          reason: reason,
          variables: Enum.join(Map.values(entry.env_vars) ++ entry.optional_env_vars, ", ")
        )

        :ok
    end
  end

  defp probe(%{probe: :smtp}, config), do: SmtpProbe.test_connection(config)
  defp probe(entry, config), do: ApiProbe.run(entry.probe, entry.label, config)

  defp validate_structure(%{probe: :smtp}, config), do: validate_smtp_structure(config)

  defp validate_structure(entry, config) do
    Enum.reduce_while(entry.required_config, :ok, fn key, :ok ->
      case validate_credential(entry, key, config[key]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_credential(entry, key, nil) do
    {:error, "#{entry.label} #{key} is required (set #{entry.env_vars[key]})"}
  end

  defp validate_credential(entry, key, value) when not is_binary(value) do
    {:error, "#{entry.label} #{key} must be a string, got: #{inspect(value)}"}
  end

  defp validate_credential(entry, key, value) do
    if String.trim(value) == "" do
      {:error, "#{entry.label} #{key} cannot be empty"}
    else
      :ok
    end
  end

  defp log_missing_adapter do
    Logger.error(
      "Mailer adapter not configured; no emails will be sent. Set EMAIL_ADAPTER.",
      supported: Enum.join(Providers.names(), ", ")
    )

    :ok
  end

  defp log_unknown_adapter(adapter) do
    Logger.warning("Mailer adapter is not in the provider registry; skipping validation",
      adapter: inspect(adapter)
    )

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
end
