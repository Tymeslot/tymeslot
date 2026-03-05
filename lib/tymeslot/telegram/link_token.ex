defmodule Tymeslot.Telegram.LinkToken do
  @moduledoc """
  Phoenix.Token wrappers for Telegram account linking.
  Encodes `{user_id, integration_id}` into a signed, time-limited token.
  """

  alias Phoenix.Token

  @salt "telegram_link"
  @max_age_seconds 600

  @spec sign(integer(), integer()) :: String.t()
  def sign(user_id, integration_id) do
    Token.sign(TymeslotWeb.Endpoint, @salt, {user_id, integration_id})
  end

  @spec verify(String.t(), keyword()) :: {:ok, {integer(), integer()}} | {:error, atom()}
  def verify(token, opts \\ []) do
    max_age = Keyword.get(opts, :max_age, @max_age_seconds)

    case Token.verify(TymeslotWeb.Endpoint, @salt, token, max_age: max_age) do
      {:ok, {user_id, integration_id}} when is_integer(user_id) and is_integer(integration_id) ->
        {:ok, {user_id, integration_id}}

      {:ok, _reason} ->
        {:error, :invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
