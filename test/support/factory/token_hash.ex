defmodule Tymeslot.Factory.TokenHash do
  @moduledoc """
  Stores a factory record's token as the hash it is looked up by, which
  factories bypassing the changeset have to do themselves. Shared by
  `Tymeslot.Factory` and the factory mixins it `use`s.
  """

  alias Tymeslot.Security.Token

  @doc """
  Puts the hash of `record`'s `field` into `hash_field`. An explicit hash
  in the attrs wins, and a record without a token is left as it is.
  """
  @spec put(struct(), atom(), atom()) :: struct()
  def put(record, field, hash_field) do
    case {Map.fetch!(record, field), Map.fetch!(record, hash_field)} do
      {token, nil} when is_binary(token) -> Map.put(record, hash_field, Token.hash_token(token))
      _no_token_or_hash_given -> record
    end
  end
end
