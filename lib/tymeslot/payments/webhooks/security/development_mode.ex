defmodule Tymeslot.Payments.Webhooks.Security.DevelopmentMode do
  @moduledoc """
  Handles webhook processing in development/test environments.
  This module should ONLY be used when explicitly configured for non-production environments.
  """

  require Logger

  alias Tymeslot.Payments.Errors.WebhookError

  @doc """
  Checks if development mode verification is enabled and appropriate.
  Returns the parsed event if conditions are met.
  """
  @spec verify_if_allowed(binary()) ::
          {:ok, map()} | {:error, :not_allowed | WebhookError.SignatureError.t()}
  def verify_if_allowed(raw_body) do
    if allowed?() do
      parse_json(raw_body)
    else
      {:error, :not_allowed}
    end
  end

  @spec allowed?() :: boolean()
  defp allowed? do
    skip_verification? = Application.get_env(:tymeslot, :skip_webhook_verification, false)

    env =
      Application.get_env(:tymeslot, :environment) ||
        case System.get_env("MIX_ENV") do
          "test" -> :test
          "dev" -> :dev
          _other -> :prod
        end

    # Only allow in test/dev environments AND when explicitly configured
    skip_verification? && env in [:test, :dev]
  end

  @spec parse_json(binary()) :: {:ok, map()} | {:error, WebhookError.SignatureError.t()}
  defp parse_json(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, event} ->
        Logger.warning("Using development mode webhook verification - NOT FOR PRODUCTION")
        {:ok, event}

      {:error, reason} ->
        {:error,
         %WebhookError.SignatureError{
           reason: :invalid_json,
           message: "Failed to parse webhook JSON in development mode",
           details: %{error: reason}
         }}
    end
  end
end
