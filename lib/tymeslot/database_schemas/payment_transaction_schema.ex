defmodule Tymeslot.DatabaseSchemas.PaymentTransactionSchema do
  @moduledoc """
  Schema for payment transactions.
  Tracks both one-time payments and subscription payments.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          amount: integer() | nil,
          status: String.t() | nil,
          stripe_id: String.t() | nil,
          stripe_customer_id: String.t() | nil,
          product_identifier: String.t() | nil,
          subscription_id: String.t() | nil,
          subscription_period: String.t() | nil,
          tax_amount: integer() | nil,
          tax_rate: Decimal.t() | nil,
          discount_amount: integer() | nil,
          tax_id: String.t() | nil,
          is_eu_business: boolean(),
          country_code: String.t() | nil,
          billing_address: map() | nil,
          payment_method: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "payment_transactions" do
    belongs_to :user, UserSchema

    # Payment details
    field :amount, :integer
    field :status, :string
    field :stripe_id, :string
    field :stripe_customer_id, :string
    field :product_identifier, :string
    field :subscription_id, :string
    field :subscription_period, :string

    # Tax information
    field :tax_amount, :integer
    field :tax_rate, :decimal
    field :discount_amount, :integer
    field :tax_id, :string
    field :is_eu_business, :boolean, default: false
    field :country_code, :string
    field :billing_address, :map
    field :payment_method, :string

    # Generic metadata
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for transaction creation and updates.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :user_id,
      :amount,
      :status,
      :stripe_id,
      :stripe_customer_id,
      :product_identifier,
      :subscription_id,
      :subscription_period,
      :tax_amount,
      :tax_rate,
      :discount_amount,
      :tax_id,
      :is_eu_business,
      :country_code,
      :billing_address,
      :payment_method,
      :metadata
    ])
    |> validate_required([:user_id, :amount, :status])
    |> validate_inclusion(:status, ~w(pending completed failed pending_reconciliation))
    |> validate_length(:country_code, is: 2)
    |> validate_number(:amount, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:stripe_id)
    |> unique_constraint(:user_id, name: :unique_pending_transaction_per_user)
  end
end
