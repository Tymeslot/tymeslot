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
        order_by: [desc: t.inserted_at, desc: t.id],
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
        order_by: [desc: t.inserted_at, desc: t.id],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Lists the distinct Stripe customer ids recorded on a user's transactions.

  A checkout creates its Stripe customer before any subscription exists, so an
  abandoned checkout leaves a customer that only the transaction row knows
  about.
  """
  @spec stripe_customer_ids_for_user(integer()) :: [String.t()]
  def stripe_customer_ids_for_user(user_id) do
    Repo.all(
      from(t in PaymentTransaction,
        where: t.user_id == ^user_id and not is_nil(t.stripe_customer_id),
        distinct: true,
        select: t.stripe_customer_id
      )
    )
  end

  @doc """
  Gets the most recent completed transaction for a Stripe customer,
  regardless of subscription.

  Used by `Payments.CustomerLookup.find_user_id/1` as the last-resort step
  when no subscription manager is configured (Core standalone) to
  attribute an invoice to a user via a Stripe customer id. Restricted to
  `completed` rows: a `pending` or `failed` transaction was never charged,
  so it is not a reliable ownership signal.
  """
  @spec get_transaction_by_stripe_customer_id(String.t()) ::
          {:ok, PaymentTransaction.t()} | {:error, :transaction_not_found}
  def get_transaction_by_stripe_customer_id(stripe_customer_id) do
    query =
      from(t in PaymentTransaction,
        where: t.stripe_customer_id == ^stripe_customer_id,
        where: t.status == "completed",
        order_by: [desc: t.inserted_at, desc: t.id],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
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
        order_by: [desc: t.inserted_at, desc: t.id],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :transaction_not_found}
      transaction -> {:ok, transaction}
    end
  end

  @doc """
  Deletes the payment transactions of deleted hosts whose statutory retention
  period has ended: every row anonymised by `anonymise_for_host/2` and created
  before `cutoff`.
  """
  @spec delete_retained_before(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_retained_before(%DateTime{} = cutoff) do
    PaymentTransaction
    |> where([t], not is_nil(t.host_deleted_at) and t.inserted_at < ^cutoff)
    |> Repo.delete_all()
  end

  @doc """
  Anonymises payment transactions for a deleted host.

  Snapshots the host's identity (email and name) from the `users` row into the
  `host_email`/`host_name` columns *before* nilifying `user_id`, then stamps
  `host_deleted_at` so the row stands alone as a tax record after the user is
  removed.

  The snapshot uses `COALESCE` so a value already captured at creation time is
  never overwritten — it only fills columns that are still null. This closes a
  retention gap: new rows are not guaranteed to have the snapshot written at
  creation, so without this fill the counterparty identity would be lost the
  moment `user_id` is set to nil. The fill mirrors the original backfill
  migration (`host_email = u.email`, `host_name = u.name`).
  """
  @spec anonymise_for_host(integer(), DateTime.t()) :: {non_neg_integer(), nil}
  def anonymise_for_host(user_id, now) do
    query =
      from t in PaymentTransaction,
        join: u in "users",
        on: u.id == t.user_id,
        where: t.user_id == ^user_id and is_nil(t.host_deleted_at),
        update: [
          set: [
            host_email: fragment("COALESCE(?, ?)", t.host_email, u.email),
            host_name: fragment("COALESCE(?, ?)", t.host_name, u.name),
            host_deleted_at: ^now,
            user_id: nil,
            updated_at: ^now
          ]
        ]

    Repo.update_all(query, [])
  end

  # The flag a handled abandoned checkout carries in its metadata. The key
  # predates the move of this bookkeeping into Core; existing rows carry it.
  @handled_key "abandoned_email_sent"

  @doc """
  Pending transactions older than `:cutoff` not yet marked handled, counted
  per user, as `{user_id, count}` tuples. `:product_identifiers` (a list) and
  `:payment_type` (matched on `metadata.payment_type`) narrow the set.
  """
  @spec list_abandoned_checkouts(keyword()) :: [{pos_integer(), pos_integer()}]
  def list_abandoned_checkouts(opts) do
    opts
    |> abandoned_scope()
    |> where(
      [t],
      fragment("coalesce(? ->> ?, 'false') = 'false'", t.metadata, ^@handled_key)
    )
    |> group_by([t], t.user_id)
    |> select([t], {t.user_id, count(t.id)})
    |> Repo.all()
  end

  @doc """
  Marks the user's pending transactions older than `:cutoff` as handled,
  under the same filters as `list_abandoned_checkouts/1`. Returns the number
  of rows marked.
  """
  @spec mark_abandoned_checkouts_handled(pos_integer(), keyword()) :: non_neg_integer()
  def mark_abandoned_checkouts_handled(user_id, opts) do
    {count, _rows} =
      opts
      |> abandoned_scope()
      |> where([t], t.user_id == ^user_id)
      |> update([t],
        set: [metadata: fragment("? || ?", t.metadata, ^%{@handled_key => "true"})]
      )
      |> Repo.update_all([])

    count
  end

  defp abandoned_scope(opts) do
    cutoff = Keyword.fetch!(opts, :cutoff)

    PaymentTransaction
    |> where([t], t.status == "pending" and t.inserted_at < ^cutoff)
    |> filter_products(Keyword.get(opts, :product_identifiers))
    |> filter_payment_type(Keyword.get(opts, :payment_type))
  end

  defp filter_products(query, nil), do: query

  defp filter_products(query, identifiers) when is_list(identifiers),
    do: where(query, [t], t.product_identifier in ^identifiers)

  defp filter_payment_type(query, nil), do: query

  defp filter_payment_type(query, payment_type) when is_binary(payment_type),
    do: where(query, [t], fragment("? ->> 'payment_type' = ?", t.metadata, ^payment_type))
end
