defmodule Tymeslot.Embed.Token do
  @moduledoc """
  Signed tokens for embedded booking pages.

  Allows LiveView WebSocket connections to work without session cookies,
  bypassing third-party cookie restrictions in cross-origin iframes.
  """

  alias Tymeslot.SignedToken

  @spec sign(String.t(), String.t() | nil) :: String.t()
  def sign(username, parent_origin \\ nil) when is_binary(username) do
    SignedToken.sign(:embed_session, {username, parent_origin})
  end

  @spec verify(String.t(), keyword()) ::
          {:ok, {String.t(), String.t() | nil}} | {:error, atom()}
  def verify(token, opts \\ []) do
    SignedToken.verify(:embed_session, token, Keyword.put(opts, :validate, &validate/1))
  end

  defp validate({username, parent_origin})
       when is_binary(username) and (is_binary(parent_origin) or is_nil(parent_origin)),
       do: {:ok, {username, parent_origin}}

  defp validate(_token), do: {:error, :invalid}
end
