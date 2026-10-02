defmodule Tymeslot.Security.EncryptedString do
  @moduledoc """
  An Ecto type for a string held encrypted at rest with
  `Tymeslot.Security.Encryption`, and as plain text everywhere else.

  The field reads and writes as an ordinary string; only the column holds
  ciphertext. It suits a value that is a secret in itself but is read wherever
  the row is, such as a webhook URL or a link the host copies again from the
  dashboard, so no caller has to remember to decrypt it:

      field(:url, EncryptedString, source: :url_encrypted)

  Encryption is randomised, so the column cannot be searched. A value that is
  also looked up needs a separate hash column beside it (see
  `Tymeslot.Security.Token.hash_token/1`).

  A stored value that no available key opens (corrupt, or written under a key
  that has since gone) loads as `nil` rather than raising, so one bad row
  cannot take down every list that includes it. The re-encryption sweep counts
  such values as unrecoverable and leaves them in place.
  """

  use Ecto.Type

  require Logger

  @impl Ecto.Type
  def type, do: :binary

  @impl Ecto.Type
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl Ecto.Type
  def dump(value) when is_binary(value), do: {:ok, encryption().encrypt(value)}
  def dump(_value), do: :error

  @impl Ecto.Type
  def load(ciphertext) when is_binary(ciphertext) do
    case encryption().decrypt_with_status(ciphertext) do
      {:ok, plaintext} ->
        {:ok, plaintext}

      {:error, :requires_reencryption} ->
        Logger.warning("Encrypted field could not be decrypted with any available key")
        {:ok, nil}
    end
  end

  def load(_value), do: :error

  # `Tymeslot.Security.Encryption`, named by an atom returned at runtime rather
  # than an alias: every schema with a field of this type depends on this
  # module at compile time, and xref would count an alias here as putting all
  # that `Encryption` reaches on each of those schemas' compile-connected
  # graph.
  defp encryption, do: :"Elixir.Tymeslot.Security.Encryption"

  @doc """
  The columns of `schema` whose fields have this type, by column name rather
  than field name, as the re-encryption sweep addresses them.
  """
  @spec columns(module()) :: [atom()]
  def columns(schema) do
    for field <- schema.__schema__(:fields),
        schema.__schema__(:type, field) == __MODULE__,
        do: schema.__schema__(:field_source, field)
  end
end
