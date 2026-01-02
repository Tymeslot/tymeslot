defmodule Tymeslot.Integrations.Common.OAuth.State do
  @moduledoc """
  Shared OAuth state utilities for generating and validating state parameters.

  Uses HMAC-SHA256 signatures with a shared secret and time-based validity.
  """

  @type user_id :: pos_integer()
  @type state :: String.t()
  @type secret :: iodata()

  @default_ttl_seconds 3600

  @doc """
  Generates a compact, signed state parameter embedding the user id and timestamp.
  """
  @spec generate(user_id(), secret()) :: state()
  def generate(user_id, secret) when is_integer(user_id) and user_id > 0 do
    timestamp = System.system_time(:second)
    data = "#{user_id}:#{timestamp}"
    signature = :crypto.mac(:hmac, :sha256, secret, data)
    encoded_data = Base.url_encode64(data)
    encoded_signature = Base.url_encode64(signature)
    "#{encoded_data}.#{encoded_signature}"
  end

  @doc """
  Validates a state parameter and returns the embedded user id if valid.

  TTL defaults to 1 hour unless provided.
  """
  @spec validate(state(), secret(), non_neg_integer()) :: {:ok, user_id()} | {:error, String.t()}
  def validate(state, secret, ttl_seconds \\ @default_ttl_seconds)

  def validate(state, _secret, _ttl) when not is_binary(state),
    do: {:error, "Invalid state parameter"}

  def validate(state, secret, ttl_seconds) do
    case String.split(state, ".", parts: 2) do
      [encoded_data, encoded_signature] ->
        with {:ok, data} <- Base.url_decode64(encoded_data),
             {:ok, signature} <- Base.url_decode64(encoded_signature),
             true <- secure_equals(signature, :crypto.mac(:hmac, :sha256, secret, data)),
             {:ok, user_id} <- extract_user_id(data, ttl_seconds) do
          {:ok, user_id}
        else
          _ -> {:error, "Invalid state parameter"}
        end

      _ ->
        {:error, "Invalid state parameter"}
    end
  end

  # Private helpers

  defp secure_equals(a, b), do: :crypto.hash_equals(a, b)

  defp extract_user_id(data, ttl_seconds) do
    case String.split(data, ":", parts: 2) do
      [user_id_str, timestamp_str] ->
        with {user_id, ""} <- Integer.parse(user_id_str),
             {timestamp, ""} <- Integer.parse(timestamp_str),
             true <- within_ttl?(timestamp, ttl_seconds) do
          {:ok, user_id}
        else
          _ -> {:error, "Invalid or expired state"}
        end

      _ ->
        {:error, "Invalid state format"}
    end
  end

  defp within_ttl?(timestamp, ttl_seconds) do
    now = System.system_time(:second)
    timestamp > now - ttl_seconds and timestamp <= now + 300
  end
end
