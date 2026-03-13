defmodule Tymeslot.Embed.Token do
  @moduledoc """
  Signed tokens for embedded booking pages.

  Allows LiveView WebSocket connections to work without session cookies,
  bypassing third-party cookie restrictions in cross-origin iframes.
  """

  alias Phoenix.Token
  alias Tymeslot.SignedToken

  @salt "embed_session"
  @max_age_seconds 21_600

  @spec sign(String.t()) :: String.t()
  def sign(username) when is_binary(username) do
    Token.sign(TymeslotWeb.Endpoint, @salt, username)
  end

  @spec verify(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def verify(token, opts \\ []) do
    max_age = Keyword.get(opts, :max_age, @max_age_seconds)
    SignedToken.verify(token, @salt, max_age, &validate/1)
  end

  defp validate(username) when is_binary(username), do: {:ok, username}
  defp validate(_), do: {:error, :invalid}
end
