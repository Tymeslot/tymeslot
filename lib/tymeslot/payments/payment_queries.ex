defmodule Tymeslot.Payments.PaymentQueries do
  @moduledoc """
  Database queries for payment transactions.
  """
  import Ecto.Query

  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction
  alias Tymeslot.Repo

  @doc """
  Creates a new payment transaction.
  """
  @spec create_transaction(map()) :: {:ok, PaymentTransaction.t()} | {:error, Ecto.Changeset.t()}
  def create_transaction(attrs) do
    %PaymentTransaction{}
    |> PaymentTransaction.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a transaction by Stripe ID.
  """
  @spec get_transaction_by_stripe_id(String.t()) ::
          {:ok, PaymentTransaction.t()} | {:error, :transaction_not_found}
  def get_transaction_by_stripe_id(stripe_id) do
    case Repo.get_by(PaymentTransaction, stripe_id: stripe_id) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Gets a transaction by Subscription ID.
  """
  @spec get_active_subscription_transaction_by_subscription_id(String.t()) ::
          {:ok, PaymentTransaction.t()} | {:error, :subscription_not_found}
  def get_active_subscription_transaction_by_subscription_id(subscription_id) do
    query =
      from(t in PaymentTransaction,
        where: t.subscription_id == ^subscription_id,
        where: t.status == "completed",
        order_by: [desc: t.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :subscription_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Gets the active subscription transaction for a user.
  """
  @spec get_active_subscription_transaction(pos_integer()) ::
          {:ok, PaymentTransaction.t()} | {:error, :subscription_not_found}
  def get_active_subscription_transaction(user_id) do
    query =
      from(t in PaymentTransaction,
        where: t.user_id == ^user_id,
        where: t.status == "completed",
        order_by: [desc: t.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :subscription_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Gets the most recent one-time transaction by Stripe customer ID.
  """
  @spec get_latest_one_time_transaction_by_customer(String.t()) ::
          {:ok, PaymentTransaction.t()} | {:error, :transaction_not_found}
  def get_latest_one_time_transaction_by_customer(stripe_customer_id) do
    query =
      from(t in PaymentTransaction,
        where: t.stripe_customer_id == ^stripe_customer_id,
        where: is_nil(t.subscription_id),
        where: t.status == "completed",
        order_by: [desc: t.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Coordinates successful subscription renewal payment by creating a new transaction record.
  """
  @spec coordinate_subscription_renewal(String.t(), map()) ::
          {:ok, PaymentTransaction.t() | :already_processed} | {:error, any()}
  def coordinate_subscription_renewal(subscription_id, invoice_data) do
    # The initial subscription invoice (billing_reason: "subscription_create") is already
    # handled by checkout.session.completed — skip it here to avoid a duplicate transaction.
    if invoice_data["billing_reason"] == "subscription_create" do
      {:ok, :already_processed}
    else
      do_coordinate_subscription_renewal(subscription_id, invoice_data)
    end
  end

  defp do_coordinate_subscription_renewal(subscription_id, invoice_data) do
    with {:ok, transaction} <-
           get_active_subscription_transaction_by_subscription_id(subscription_id) do
      # Create a NEW transaction record for the renewal instead of updating the old one
      renewal_attrs = %{
        user_id: transaction.user_id,
        amount: invoice_data["amount_paid"] || transaction.amount,
        status: "completed",
        # Use the invoice ID as the stripe_id for this transaction
        stripe_id: invoice_data["id"],
        stripe_customer_id: transaction.stripe_customer_id,
        product_identifier: transaction.product_identifier,
        subscription_id: subscription_id,
        metadata:
          Map.merge(transaction.metadata, %{
            renewal_invoice_id: invoice_data["id"],
            renewal_date: invoice_data["created"],
            original_transaction_id: transaction.id
          })
      }

      create_transaction(renewal_attrs)
    end
  end

  @doc """
  Updates a transaction.
  """
  @spec update_transaction(PaymentTransaction.t(), map()) ::
          {:ok, PaymentTransaction.t()} | {:error, Ecto.Changeset.t()}
  def update_transaction(transaction, attrs) do
    transaction
    |> PaymentTransaction.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates transaction status.
  """
  @spec update_transaction_status(PaymentTransaction.t(), String.t()) ::
          {:ok, PaymentTransaction.t()} | {:error, Ecto.Changeset.t()}
  def update_transaction_status(transaction, status) do
    update_transaction(transaction, %{status: status})
  end

  @doc """
  Gets transactions by status for a specific user.
  """
  @spec get_transactions_by_status(String.t(), pos_integer()) ::
          {:ok, [PaymentTransaction.t()]} | {:error, term()}
  def get_transactions_by_status(status, user_id) do
    query =
      from(t in PaymentTransaction,
        where: t.status == ^status,
        where: t.user_id == ^user_id
      )

    try do
      {:ok, Repo.all(query)}
    rescue
      error ->
        {:error, error}
    end
  end

  @doc """
  Gets the pending subscription transaction for a user.
  """
  @spec get_pending_subscription_transaction(pos_integer()) ::
          {:ok, PaymentTransaction.t()} | {:error, :transaction_not_found}
  def get_pending_subscription_transaction(user_id) do
    query =
      from(t in PaymentTransaction,
        where: t.user_id == ^user_id,
        where: t.status == "pending",
        where: fragment("? ->> 'payment_type' = ?", t.metadata, "subscription"),
        order_by: [desc: t.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Gets all pending subscription transactions for a user.
  """
  @spec get_pending_subscription_transactions(pos_integer()) ::
          {:ok, [PaymentTransaction.t()]}
  def get_pending_subscription_transactions(user_id) do
    query =
      from(t in PaymentTransaction,
        where: t.user_id == ^user_id,
        where: t.status == "pending",
        where: fragment("? ->> 'payment_type' = ?", t.metadata, "subscription"),
        order_by: [desc: t.inserted_at]
      )

    {:ok, Repo.all(query)}
  end

  @doc """
  Gets transactions by status.
  """
  @spec get_transactions_by_status(String.t()) ::
          {:ok, [PaymentTransaction.t()]} | {:error, term()}
  def get_transactions_by_status(status) do
    query = from(t in PaymentTransaction, where: t.status == ^status)

    try do
      {:ok, Repo.all(query)}
    rescue
      error ->
        {:error, error}
    end
  end

  @doc """
  Coordinates successful payment update with tax information.

  Accepts either a transaction struct (skips the DB lookup) or a Stripe ID string.
  """
  @spec coordinate_successful_payment(PaymentTransaction.t() | String.t(), map(), integer()) ::
          {:ok, PaymentTransaction.t()} | {:error, any()}
  def coordinate_successful_payment(transaction_or_id, tax_info \\ %{}, discount_amount \\ 0)

  def coordinate_successful_payment(
        %PaymentTransaction{} = transaction,
        tax_info,
        discount_amount
      ) do
    update_attrs = %{
      status: "completed",
      tax_amount: Map.get(tax_info, :tax_amount),
      tax_rate: Map.get(tax_info, :tax_rate),
      tax_id: Map.get(tax_info, :tax_id),
      is_eu_business: Map.get(tax_info, :is_eu_business, false),
      country_code: Map.get(tax_info, :country_code),
      billing_address: Map.get(tax_info, :billing_address),
      discount_amount: discount_amount
    }

    update_transaction(transaction, update_attrs)
  end

  def coordinate_successful_payment(stripe_id, tax_info, discount_amount) do
    with {:ok, transaction} <- get_transaction_by_stripe_id(stripe_id) do
      coordinate_successful_payment(transaction, tax_info, discount_amount)
    end
  end

  @doc """
  Anonymises payment transactions for a deleted host.

  Nilifies user_id and stamps host_deleted_at so the row stands alone as
  a tax record after the user is removed. host_email and host_name are
  retained — they're the snapshotted counterparty identity required for
  compliance and are not scrubbed here.
  """
  @spec anonymise_for_host(integer(), DateTime.t()) :: {non_neg_integer(), nil}
  def anonymise_for_host(user_id, now) do
    query =
      from t in PaymentTransaction,
        where: t.user_id == ^user_id and is_nil(t.host_deleted_at)

    Repo.update_all(query,
      set: [
        host_deleted_at: now,
        user_id: nil,
        updated_at: now
      ]
    )
  end
end
