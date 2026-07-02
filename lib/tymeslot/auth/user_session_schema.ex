defmodule Tymeslot.Auth.UserSessionSchema do
  @moduledoc """
  Schema for user session tokens.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          token: String.t() | nil,
          token_hash: String.t() | nil,
          expires_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "user_sessions" do
    belongs_to(:user, Tymeslot.Auth.UserSchema)
    # SHA-256 hash of the session token. The plaintext token lives only in the
    # user's cookie; it is never stored at rest.
    field(:token_hash, :string)
    # Plaintext token, virtual (never persisted). Convenience for callers/tests
    # that want to hold the plaintext alongside its hash. Redacted from inspect.
    field(:token, :string, virtual: true, redact: true)
    field(:expires_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [:user_id, :token_hash, :expires_at])
    |> validate_required([:user_id, :token_hash, :expires_at])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
  end
end
