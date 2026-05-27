defmodule Tymeslot.Payments.MetadataSanitizer do
  @moduledoc """
  Sanitizes user-provided metadata before storing or sending to payment providers.

  This module ensures that:
  - Only whitelisted keys are allowed
  - Values have appropriate types and lengths
  - Potentially malicious content is stripped
  - System-critical keys cannot be overwritten by user input
  """

  require Logger

  # Maximum length for any metadata value
  @max_value_length 500

  # System-reserved keys that cannot be overwritten by user input
  @system_reserved_keys ~w(
    user_id
    product_identifier
    payment_type
    transaction_id
    subscription_id
    checkout_request_id
  )

  # Whitelisted keys that users can provide
  @allowed_user_keys ~w(
    billing_interval
    campaign_id
    custom_field_1
    custom_field_2
    custom_field_3
    referral_code
    utm_campaign
    utm_medium
    utm_source
  )

  @doc """
  Sanitizes metadata by filtering allowed keys and validating values.

  ## Parameters
    * metadata - User-provided metadata map (string or atom keys)
    * system_metadata - System-provided metadata that takes precedence (optional)

  ## Returns
    * Sanitized metadata map with string keys

  ## Examples

      iex> sanitize(%{"referral_code" => "ABC123"})
      {:ok, %{"referral_code" => "ABC123"}}

      iex> sanitize(%{"malicious_key" => "value"})
      {:ok, %{}}

      iex> sanitize(%{"referral_code" => String.duplicate("A", 1000)})
      {:error, :value_too_long}
  """
  @spec sanitize(map(), map()) :: {:ok, map()} | {:error, :value_too_long}
  def sanitize(metadata, system_metadata \\ %{}) when is_map(metadata) do
    user_metadata = metadata |> stringify_keys() |> filter_and_validate_user_metadata()

    case user_metadata do
      {:ok, validated_metadata} ->
        # System metadata takes precedence and cannot be overwritten
        final_metadata = Map.merge(validated_metadata, stringify_keys(system_metadata))

        {:ok, final_metadata}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Sanitizes metadata, raising on error.
  """
  @spec sanitize!(map(), map()) :: map()
  def sanitize!(metadata, system_metadata \\ %{}) do
    case sanitize(metadata, system_metadata) do
      {:ok, sanitized} -> sanitized
      {:error, reason} -> raise ArgumentError, "Metadata sanitization failed: #{reason}"
    end
  end

  # Converts all keys to strings
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  # Filters metadata to only allowed keys and validates values
  defp filter_and_validate_user_metadata(metadata) do
    result =
      metadata
      |> Enum.filter(fn {key, _value} -> key in @allowed_user_keys end)
      |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case validate_value(value) do
          :ok ->
            sanitized_value = sanitize_value(value)
            {:cont, {:ok, Map.put(acc, key, sanitized_value)}}

          {:error, reason} ->
            Logger.warning("Metadata validation failed", key: key, reason: reason)
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, filtered} ->
        # Log if any keys were filtered out (helps detect issues)
        filtered_out = Map.keys(metadata) -- Map.keys(filtered)

        if filtered_out != [] do
          Logger.debug("Filtered out non-whitelisted metadata keys", keys: filtered_out)
        end

        {:ok, filtered}

      error ->
        error
    end
  end

  # Validates that a value meets requirements
  defp validate_value(value) when is_binary(value) do
    if String.length(value) <= @max_value_length do
      :ok
    else
      {:error, :value_too_long}
    end
  end

  defp validate_value(value) when is_number(value), do: :ok
  defp validate_value(value) when is_boolean(value), do: :ok
  defp validate_value(nil), do: :ok

  defp validate_value(_value) do
    {:error, :invalid_type}
  end

  # Sanitizes a value by removing potentially harmful content
  defp sanitize_value(value) when is_binary(value) do
    value
    |> String.trim()
    # Remove any HTML tags
    |> strip_html()
    # Remove control characters except newlines and tabs
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
  end

  defp sanitize_value(value), do: value

  # Strips HTML tags from a string
  defp strip_html(string) do
    string
    # First remove script tags and their content (including newlines)
    |> String.replace(~r/<script[^>]*>.*?<\/script>/is, "")
    # Then remove all other HTML tags
    |> String.replace(~r/<[^>]*>/, "")
  end

  @doc """
  Checks if a key is system-reserved and should not be overwritten by user input.
  """
  @spec system_reserved?(String.t() | atom()) :: boolean()
  def system_reserved?(key) when is_atom(key), do: system_reserved?(Atom.to_string(key))
  def system_reserved?(key) when is_binary(key), do: key in @system_reserved_keys

  @doc """
  Returns the list of allowed user metadata keys.
  """
  @spec allowed_keys() :: [String.t()]
  def allowed_keys, do: @allowed_user_keys
end
