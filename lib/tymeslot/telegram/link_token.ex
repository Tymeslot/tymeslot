defmodule Tymeslot.Telegram.LinkToken do
  @moduledoc """
  Phoenix.Token wrappers for Telegram account linking.
  Encodes `{user_id, integration_id}` into a signed, time-limited token.
  """

  alias Phoenix.Token
  alias Tymeslot.SignedToken

  @salt "telegram_link"
  @max_age_seconds 600

  @spec sign(integer(), integer()) :: String.t()
  def sign(user_id, integration_id) do
    Token.sign(TymeslotWeb.Endpoint, @salt, {user_id, integration_id})
  end

  @spec verify(String.t(), keyword()) :: {:ok, {integer(), integer()}} | {:error, atom()}
  def verify(token, opts \\ []) do
    max_age = Keyword.get(opts, :max_age, @max_age_seconds)
    SignedToken.verify(token, @salt, max_age, &validate/1)
  end

  defp validate({user_id, integration_id})
       when is_integer(user_id) and is_integer(integration_id),
       do: {:ok, {user_id, integration_id}}

  defp validate(_), do: {:error, :invalid}
end
