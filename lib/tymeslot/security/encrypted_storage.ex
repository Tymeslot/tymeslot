defmodule Tymeslot.Security.EncryptedStorage do
  @moduledoc """
  Behaviour for domain context modules that persist encrypted credentials.

  Implementing this on a context module lets `Tymeslot.Security.CredentialReencryption`
  discover which table and columns hold at-rest secrets for that domain without
  reaching past the context boundary into its internal schema. The context is
  expected to delegate to its own schema's `encrypted_credential_fields/0` (and
  `__schema__(:source)`) internally — the schema remains the authoritative source,
  the context merely re-exposes it through the public boundary.

  Any new integration that stores encrypted credentials should implement this
  callback on its context module.
  """

  @typedoc "A table and the encrypted columns the domain owns in it."
  @type table :: {table_source :: String.t(), columns :: [atom()]}

  @doc """
  Returns the table source and the encrypted columns the domain owns, or a
  list of them for a domain keeping encrypted columns in several tables.
  """
  @callback encrypted_storage() :: table() | [table()]
end
