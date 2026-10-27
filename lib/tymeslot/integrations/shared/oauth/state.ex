defmodule Tymeslot.Integrations.Shared.OAuth.State do
  @moduledoc """
  Shared OAuth state utilities for generating and validating state parameters.

  Uses HMAC-SHA256 signatures with a shared secret and time-based validity.
  Optionally embeds an integration_id for re-authorization flows.
  """

  alias Tymeslot.Integrations.Shared.OAuthConfig
  alias Tymeslot.Security.RedirectPath

  @type user_id :: pos_integer()
  @type state :: String.t()
  @type secret :: iodata()
  @type validated :: %{
          user_id: user_id(),
          integration_id: pos_integer() | nil,
          return_to: String.t() | nil,
          nonce: String.t() | nil
        }

  @default_ttl_seconds 3600

  @doc """
  Generates a compact, signed state parameter embedding the user id, timestamp,
  and optionally an integration_id for re-authorization and a return_to path.

  ## Options
    - `:return_to`: a relative path to redirect to after the OAuth callback,
      embedded after a `|` separator in the signed data. Dropped unless
      `Tymeslot.Security.RedirectPath.safe?/1` accepts it.
    - `:nonce`: the key of the flow's
      `Tymeslot.Integrations.Shared.OAuth.PendingFlow`, which makes the state
      single-use. URL-safe base64, so it cannot contain the separators.
  """
  @spec generate(user_id(), secret(), pos_integer() | nil, keyword()) :: state()
  def generate(user_id, secret, integration_id \\ nil, opts \\ [])
      when is_integer(user_id) and user_id > 0 do
    timestamp = System.system_time(:second)
    return_to = Keyword.get(opts, :return_to)

    core =
      case {integration_id, Keyword.get(opts, :nonce)} do
        {nil, nil} -> "#{user_id}:#{timestamp}"
        {id, nil} -> "#{user_id}:#{timestamp}:#{id}"
        {id, nonce} -> "#{user_id}:#{timestamp}:#{id}:#{nonce}"
      end

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
  Validates a callback's `state` against the provider's state secret and
  checks it was issued to `user_id`, the user completing the callback.

  This is the domain's own guard: binding the signed state to the acting user
  is what stops a code issued for one person's account being connected to
  another person's Tymeslot user, so it cannot be left to the web layer.
  """
  @spec verify(term(), OAuthConfig.provider(), user_id()) ::
          {:ok, validated()} | {:error, :state_user_mismatch | String.t()}
  def verify(state, provider, user_id) when is_integer(user_id) do
    case validate(state, OAuthConfig.fetch!(provider, :state_secret)) do
      {:ok, %{user_id: ^user_id} = validated} -> {:ok, validated}
      {:ok, _issued_to_another_user} -> {:error, :state_user_mismatch}
      {:error, _reason} = error -> error
    end
  end

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
        parse_state_parts([user_id_str, timestamp_str, nil, nil], return_to, ttl_seconds)

      [user_id_str, timestamp_str, integration_id_str] ->
        parse_state_parts(
          [user_id_str, timestamp_str, integration_id_str, nil],
          return_to,
          ttl_seconds
        )

      [_user_id_str, _timestamp_str, _integration_id_str, nonce] = fields when nonce != "" ->
        parse_state_parts(fields, return_to, ttl_seconds)

      _other ->
        {:error, "Invalid state format"}
    end
  end

  defp parse_state_parts(
         [user_id_str, timestamp_str, integration_id_str, nonce],
         return_to,
         ttl_seconds
       ) do
    with {user_id, ""} <- Integer.parse(user_id_str),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         true <- within_ttl?(timestamp, ttl_seconds),
         {:ok, integration_id} <- parse_optional_integration_id(integration_id_str) do
      validated_return_to = if valid_return_to?(return_to), do: return_to

      {:ok,
       %{
         user_id: user_id,
         integration_id: integration_id,
         return_to: validated_return_to,
         nonce: nonce
       }}
    else
      _error -> {:error, "Invalid or expired state"}
    end
  end

  defp parse_optional_integration_id(nil), do: {:ok, nil}
  defp parse_optional_integration_id(""), do: {:ok, nil}

  defp parse_optional_integration_id(str) do
    case Integer.parse(str) do
      {id, ""} -> {:ok, id}
      _other -> {:error, "Invalid integration_id"}
    end
  end

  defp valid_return_to?(path), do: RedirectPath.safe?(path)

  defp within_ttl?(timestamp, ttl_seconds) do
    now = System.system_time(:second)
    timestamp > now - ttl_seconds and timestamp <= now + 300
  end
end
