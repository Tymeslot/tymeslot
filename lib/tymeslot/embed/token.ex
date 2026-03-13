defmodule Tymeslot.Embed.Token do
  @moduledoc """
  Signed tokens for embedded booking pages.

  Allows LiveView WebSocket connections to work without session cookies,
  bypassing third-party cookie restrictions in cross-origin iframes.
  """

  alias Phoenix.Token

  @salt "embed_session"
  @max_age_seconds 21_600

  @spec sign(String.t()) :: String.t()
  def sign(username) when is_binary(username) do
    Token.sign(TymeslotWeb.Endpoint, @salt, username)
  end

  @spec verify(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def verify(token, opts \\ []) do
    max_age = Keyword.get(opts, :max_age, @max_age_seconds)

    case Token.verify(TymeslotWeb.Endpoint, @salt, token, max_age: max_age) do
      {:ok, username} when is_binary(username) -> {:ok, username}
      {:ok, _invalid} -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end
end
