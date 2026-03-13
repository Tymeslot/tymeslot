defmodule Tymeslot.SignedToken do
  @moduledoc """
  Shared helpers for Phoenix.Token sign/verify operations.
  """

  alias Phoenix.Token

  @doc """
  Verifies a signed token and validates its payload using the given function.

  Returns `{:ok, value}` if the token is valid and `validate.(value)` returns `{:ok, value}`,
  or `{:error, reason}` otherwise.
  """
  @spec verify(String.t(), String.t(), pos_integer(), (term() -> {:ok, term()} | {:error, atom()})) ::
          {:ok, term()} | {:error, atom()}
  def verify(token, salt, max_age, validate) do
    case Token.verify(TymeslotWeb.Endpoint, salt, token, max_age: max_age) do
      {:ok, value} -> validate.(value)
      {:error, reason} -> {:error, reason}
    end
  end
end
