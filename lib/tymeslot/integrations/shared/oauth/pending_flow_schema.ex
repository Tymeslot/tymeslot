defmodule Tymeslot.Integrations.Shared.OAuth.PendingFlowSchema do
  @moduledoc """
  An integration OAuth flow a user has started and whose callback has not
  yet been consumed: the PKCE code verifier, encrypted at rest, keyed by the
  nonce the flow's signed `state` carries.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "oauth_pending_flows" do
    field :nonce, :string
    field :provider, :string
    field :code_verifier_encrypted, :binary
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :user, Tymeslot.Auth.UserSchema

    timestamps(type: :utc_datetime)
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(flow, attrs) do
    flow
    |> cast(attrs, [:nonce, :user_id, :provider, :code_verifier_encrypted, :expires_at])
    |> validate_required([:nonce, :user_id, :provider, :code_verifier_encrypted, :expires_at])
    |> unique_constraint(:nonce)
    |> foreign_key_constraint(:user_id)
  end
end
