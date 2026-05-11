defmodule Tymeslot.MeetingPayments.ConnectAccountSchema do
  @moduledoc """
  Stripe Connect account linked to a Tymeslot host.

  status values:
    * "creating" — placeholder row; Stripe.Account.create has not yet succeeded
    * "active"   — Stripe account exists and the row tracks its current state
    * "deleted"  — host disconnected or was deleted; user_id nilified
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @valid_statuses ~w(creating active deleted)

  @type t :: %__MODULE__{}

  schema "connect_accounts" do
    field :stripe_account_id, :string
    field :country, :string
    field :default_currency, :string
    field :charges_enabled, :boolean, default: false
    field :payouts_enabled, :boolean, default: false
    field :details_submitted, :boolean, default: false
    field :disabled_reason, :string
    field :last_synced_at, :utc_datetime
    field :last_account_event_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :status, :string, default: "creating"

    belongs_to :user, UserSchema, type: :id
    timestamps()
  end

  @castable ~w(
    user_id stripe_account_id country default_currency
    charges_enabled payouts_enabled details_submitted disabled_reason
    last_synced_at last_account_event_at deleted_at status
  )a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, @castable)
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:stripe_account_id,
      name: :connect_accounts_stripe_account_id_live_unique_index
    )
    |> unique_constraint(:user_id, name: :connect_accounts_user_id_live_unique_index)
    |> foreign_key_constraint(:user_id)
  end

  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses
end
