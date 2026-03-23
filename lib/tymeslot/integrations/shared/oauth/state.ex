defmodule Tymeslot.Integrations.Common.OAuth.State do
  @moduledoc """
  Shared OAuth state utilities for generating and validating state parameters.

  Uses HMAC-SHA256 signatures with a shared secret and time-based validity.
  Optionally embeds an integration_id for re-authorization flows.
  """

  @type user_id :: pos_integer()
  @type state :: String.t()
  @type secret :: iodata()
  @type validated :: %{user_id: user_id(), integration_id: pos_integer() | nil}

  @default_ttl_seconds 3600

  @doc """
  Generates a compact, signed state parameter embedding the user id, timestamp,
  and optionally an integration_id for re-authorization.
  """
  @spec generate(user_id(), secret(), pos_integer() | nil) :: state()
  def generate(user_id, secret, integration_id \\ nil)
      when is_integer(user_id) and user_id > 0 do
    timestamp = System.system_time(:second)

    data =
      if integration_id,
        do: "#{user_id}:#{timestamp}:#{integration_id}",
        else: "#{user_id}:#{timestamp}"

    signature = :crypto.mac(:hmac, :sha256, secret, data)
    encoded_data = Base.url_encode64(data)
    encoded_signature = Base.url_encode64(signature)
    "#{encoded_data}.#{encoded_signature}"
  end

  @doc """
  Validates a state parameter and returns a map with user_id and optional integration_id.

  TTL defaults to 1 hour unless provided.
  """
  @spec validate(state(), secret(), non_neg_integer()) ::
          {:ok, validated()} | {:error, String.t()}
  def validate(state, secret, ttl_seconds \\ @default_ttl_seconds)

  def validate(state, _secret, _ttl) when not is_binary(state),
    do: {:error, "Invalid state parameter"}

  def validate(state, secret, ttl_seconds) do
    case String.split(state, ".", parts: 2) do
      [encoded_data, encoded_signature] ->
        with {:ok, data} <- Base.url_decode64(encoded_data),
             {:ok, signature} <- Base.url_decode64(encoded_signature),
             true <- secure_equals(signature, :crypto.mac(:hmac, :sha256, secret, data)),
             {:ok, result} <- extract_state_data(data, ttl_seconds) do
          {:ok, result}
        else
          {:error, _reason} = error -> error
          false -> {:error, "Invalid state parameter"}
        end

      _other ->
        {:error, "Invalid state parameter"}
    end
  end

  # Private helpers

  defp secure_equals(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equals(_a, _b), do: false

  defp extract_state_data(data, ttl_seconds) do
    parts = String.split(data, ":")

    case parts do
      [user_id_str, timestamp_str] ->
        parse_state_parts(user_id_str, timestamp_str, nil, ttl_seconds)

      [user_id_str, timestamp_str, integration_id_str] ->
        parse_state_parts(user_id_str, timestamp_str, integration_id_str, ttl_seconds)

      _other ->
        {:error, "Invalid state format"}
    end
  end

  defp parse_state_parts(user_id_str, timestamp_str, integration_id_str, ttl_seconds) do
    with {user_id, ""} <- Integer.parse(user_id_str),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         true <- within_ttl?(timestamp, ttl_seconds),
         {:ok, integration_id} <- parse_optional_integration_id(integration_id_str) do
      {:ok, %{user_id: user_id, integration_id: integration_id}}
    else
      _error -> {:error, "Invalid or expired state"}
    end
  end

  defp parse_optional_integration_id(nil), do: {:ok, nil}

  defp parse_optional_integration_id(str) do
    case Integer.parse(str) do
      {id, ""} -> {:ok, id}
      _other -> {:error, "Invalid integration_id"}
    end
  end

  defp within_ttl?(timestamp, ttl_seconds) do
    now = System.system_time(:second)
    timestamp > now - ttl_seconds and timestamp <= now + 300
  end
end
