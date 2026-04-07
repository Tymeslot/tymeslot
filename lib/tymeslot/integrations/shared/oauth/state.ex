defmodule Tymeslot.Integrations.Common.OAuth.State do
  @moduledoc """
  Shared OAuth state utilities for generating and validating state parameters.

  Uses HMAC-SHA256 signatures with a shared secret and time-based validity.
  Optionally embeds an integration_id for re-authorization flows.
  """

  @type user_id :: pos_integer()
  @type state :: String.t()
  @type secret :: iodata()
  @type validated :: %{
          user_id: user_id(),
          integration_id: pos_integer() | nil,
          return_to: String.t() | nil
        }

  @default_ttl_seconds 3600

  @doc """
  Generates a compact, signed state parameter embedding the user id, timestamp,
  and optionally an integration_id for re-authorization and a return_to path.

  ## Options
    - `:return_to` — a relative path (starting with `/`) to redirect to after
      the OAuth callback. Embedded after a `|` separator in the signed data.
  """
  @spec generate(user_id(), secret(), pos_integer() | nil, keyword()) :: state()
  def generate(user_id, secret, integration_id \\ nil, opts \\ [])
      when is_integer(user_id) and user_id > 0 do
    timestamp = System.system_time(:second)
    return_to = Keyword.get(opts, :return_to)

    core =
      if integration_id,
        do: "#{user_id}:#{timestamp}:#{integration_id}",
        else: "#{user_id}:#{timestamp}"

    data =
      if valid_return_to?(return_to),
        do: "#{core}|#{return_to}",
        else: core

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

  @doc """
  Extracts the `return_to` path from a state string without full validation.

  Only use this after `validate/3` has already confirmed the state is authentic.
  Returns `nil` when no `return_to` was embedded.
  """
  @spec peek_return_to(state()) :: String.t() | nil
  def peek_return_to(state) when is_binary(state) do
    with [encoded_data, _sig] <- String.split(state, ".", parts: 2),
         {:ok, data} <- Base.url_decode64(encoded_data),
         [_core, return_to] <- String.split(data, "|", parts: 2) do
      if valid_return_to?(return_to), do: return_to
    else
      _other -> nil
    end
  end

  def peek_return_to(_other), do: nil

  # Private helpers

  defp secure_equals(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_equals(_a, _b), do: false

  defp extract_state_data(data, ttl_seconds) do
    {core, return_to} =
      case String.split(data, "|", parts: 2) do
        [core, return_to] -> {core, return_to}
        [core] -> {core, nil}
      end

    parts = String.split(core, ":")

    case parts do
      [user_id_str, timestamp_str] ->
        parse_state_parts(user_id_str, timestamp_str, nil, return_to, ttl_seconds)

      [user_id_str, timestamp_str, integration_id_str] ->
        parse_state_parts(user_id_str, timestamp_str, integration_id_str, return_to, ttl_seconds)

      _other ->
        {:error, "Invalid state format"}
    end
  end

  defp parse_state_parts(user_id_str, timestamp_str, integration_id_str, return_to, ttl_seconds) do
    with {user_id, ""} <- Integer.parse(user_id_str),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         true <- within_ttl?(timestamp, ttl_seconds),
         {:ok, integration_id} <- parse_optional_integration_id(integration_id_str) do
      validated_return_to = if valid_return_to?(return_to), do: return_to
      {:ok, %{user_id: user_id, integration_id: integration_id, return_to: validated_return_to}}
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

  defp valid_return_to?(path) when is_binary(path) do
    String.starts_with?(path, "/") and not String.starts_with?(path, "//")
  end

  defp valid_return_to?(_other), do: false

  defp within_ttl?(timestamp, ttl_seconds) do
    now = System.system_time(:second)
    timestamp > now - ttl_seconds and timestamp <= now + 300
  end
end
