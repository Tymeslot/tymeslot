defmodule Tymeslot.Payments.Webhooks.Security.SignatureVerifier do
  @moduledoc """
  Domain-focused module for Stripe webhook signature verification.
  Handles the security aspects of webhook processing with clear separation of concerns.
  """

  require Logger

  alias Tymeslot.Payments.Config
  alias Tymeslot.Payments.Errors.WebhookError

  @type verification_result :: {:ok, map()} | {:error, WebhookError.SignatureError.t()}

  @doc """
  Verifies a Stripe webhook signature and returns the parsed event.
  """
  @spec verify(binary(), String.t()) :: verification_result()
  def verify(raw_body, signature) do
    with {:ok, webhook_secret} <- get_webhook_secret(),
         {:ok, event} <- verify_with_stripe(raw_body, signature, webhook_secret) do
      {:ok, normalize_event(event)}
    end
  end

  # Private functions for better cohesion and single responsibility

  @spec get_webhook_secret() :: {:ok, String.t()} | {:error, WebhookError.SignatureError.t()}
  defp get_webhook_secret do
    case stripe_provider().webhook_secret() do
      nil ->
        {:error,
         %WebhookError.SignatureError{
           reason: :missing_webhook_secret,
           message: "STRIPE_WEBHOOK_SECRET environment variable is not set"
         }}

      "" ->
        {:error,
         %WebhookError.SignatureError{
           reason: :missing_webhook_secret,
           message: "STRIPE_WEBHOOK_SECRET environment variable is empty"
         }}

      secret ->
        {:ok, secret}
    end
  end

  @spec verify_with_stripe(binary(), String.t(), String.t()) :: verification_result()
  defp verify_with_stripe(raw_body, signature, webhook_secret) do
    case stripe_provider().construct_webhook_event(raw_body, signature, webhook_secret) do
      {:ok, event} ->
        {:ok, event}

      {:error, reason} ->
        Logger.error("Stripe signature verification failed: #{inspect(reason)}")

        {:error,
         %WebhookError.SignatureError{
           reason: :invalid_signature,
           message: "Invalid Stripe signature",
           details: %{error: reason}
         }}
    end
  rescue
    e ->
      Logger.error("Exception during signature verification: #{inspect(e)}")

      {:error,
       %WebhookError.SignatureError{
         reason: :verification_exception,
         message: "Exception during signature verification",
         details: %{exception: Exception.message(e)}
       }}
  end

  @spec normalize_event(map()) :: map()
  defp normalize_event(%{__struct__: _value} = event) do
    struct_to_map(event)
  end

  defp normalize_event(%{data: %{object: object}} = event) when is_struct(object) do
    %{event | data: %{object: struct_to_map(object)}}
  end

  defp normalize_event(event), do: event

  @spec struct_to_map(any()) :: any()
  defp struct_to_map(%{__struct__: _value} = struct) do
    struct
    |> Map.from_struct()
    |> Enum.map(fn {k, v} -> {to_string(k), struct_to_map(v)} end)
    |> Enum.into(%{})
  end

  defp struct_to_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), struct_to_map(v)} end)
    |> Enum.into(%{})
  end

  defp struct_to_map(list) when is_list(list) do
    Enum.map(list, &struct_to_map/1)
  end

  defp struct_to_map(value), do: value

  defp stripe_provider do
    Config.stripe_provider()
  end
end
