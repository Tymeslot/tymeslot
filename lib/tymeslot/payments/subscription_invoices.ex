defmodule Tymeslot.Payments.SubscriptionInvoices do
  @moduledoc """
  Business rules for capturing a subscription's Stripe invoices and creating
  the payment transaction each renewal bills against.

  Covers platform subscription invoices only; see
  `SubscriptionInvoiceSchema` for why Connect direct-charge booking invoices
  are deliberately out of scope.

  Two separate reasons to change live here, deliberately kept as two
  functions rather than folded into one:

    * `capture/1` — invoice-document policy. An invoice is not an attribute
      of a transaction: Stripe finalises every invoice independently of
      whether the transaction it eventually relates to exists yet, so this
      upserts on the invoice's own id (`SubscriptionInvoiceQueries.upsert/1`),
      owned by the user `CustomerLookup.find_user_id/1` resolves for it —
      never re-derived from `payment_transactions` heuristics here.
    * `coordinate_renewal/1` — pre-existing renewal-transaction creation,
      unrelated to invoice documents beyond sharing the same webhook event.
  """

  require Logger

  alias Tymeslot.Payments.CustomerLookup
  alias Tymeslot.Payments.PaymentQueries
  alias Tymeslot.Payments.PaymentTransactionSchema, as: PaymentTransaction
  alias Tymeslot.Payments.SubscriptionInvoice
  alias Tymeslot.Payments.SubscriptionInvoiceQueries
  alias Tymeslot.Payments.SubscriptionInvoiceSchema
  alias Tymeslot.Payments.Webhooks.InvoiceEvent

  @subscription_create "subscription_create"

  @doc """
  Lists a user's invoices, newest first.
  """
  @spec list(pos_integer()) :: [SubscriptionInvoice.t()]
  def list(user_id) do
    user_id
    |> SubscriptionInvoiceQueries.list_for_user()
    |> Enum.map(&SubscriptionInvoice.from_schema/1)
  end

  @spec list(pos_integer(), pos_integer()) :: [SubscriptionInvoice.t()]
  def list(user_id, limit) do
    user_id
    |> SubscriptionInvoiceQueries.list_for_user(limit)
    |> Enum.map(&SubscriptionInvoice.from_schema/1)
  end

  @doc """
  Captures (inserts or merges) the invoice document described by `event`.

  Resolves the owning user via `CustomerLookup.find_user_id/1`, the same
  canonical customer/subscription -> user resolver `CustomerLookup` and
  `TrialWillEndHandler` already use elsewhere. That resolution never blocks
  the capture: an invoice whose owner cannot be resolved is still captured,
  just with a `nil` `user_id` — logged as a warning, since there is no
  active job that later reconciles an orphaned invoice. A later webhook
  event for the *same* invoice can still fill `user_id` in by then
  (`SubscriptionInvoiceQueries.upsert/1`'s per-field `COALESCE`), but that is
  opportunistic, not guaranteed.

  A resolved `user_id` can still point at an already-deleted user: SaaS
  retains its `subscriptions` row (and its `user_id`) after account
  deletion for audit purposes, with no foreign key tying it to `users`, so
  `find_user_id/1` can hand back a dead id. `subscription_invoices.user_id`
  *does* have a foreign key, so inserting or upserting against that id
  fails on a constraint violation. Rather than lose the invoice — it is a
  retained tax document, and losing it is strictly worse than storing it
  unowned — a foreign key violation on `user_id` is retried once with
  `user_id: nil`.
  """
  @spec capture(InvoiceEvent.t()) ::
          {:ok, SubscriptionInvoiceSchema.t()} | {:error, Ecto.Changeset.t()}
  def capture(%InvoiceEvent{} = event) do
    attrs = %{
      stripe_invoice_id: event.id,
      user_id: resolve_user_id(event),
      subscription_id: event.subscription_id,
      number: event.number,
      currency: event.currency,
      amount_cents: event.amount_cents,
      issued_at: event.issued_at,
      hosted_invoice_url: event.hosted_url,
      invoice_pdf_url: event.pdf_url,
      status: event.status,
      paid_at: event.paid_at
    }

    attrs
    |> SubscriptionInvoiceQueries.upsert()
    |> retry_without_owner_on_fk_violation(attrs)
  end

  defp retry_without_owner_on_fk_violation({:error, %Ecto.Changeset{} = changeset}, attrs) do
    if user_id_fk_violation?(changeset) do
      Logger.warning(
        "Invoice owner resolved to a since-deleted user, capturing with no owner instead",
        stripe_invoice_id: attrs.stripe_invoice_id,
        user_id: attrs.user_id
      )

      SubscriptionInvoiceQueries.upsert(%{attrs | user_id: nil})
    else
      {:error, changeset}
    end
  end

  defp retry_without_owner_on_fk_violation(result, _attrs), do: result

  defp user_id_fk_violation?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:user_id, {_message, opts}} -> Keyword.get(opts, :constraint) == :foreign
      _other_error -> false
    end)
  end

  defp resolve_user_id(%InvoiceEvent{} = event) do
    case CustomerLookup.find_user_id(%{
           subscription_id: event.subscription_id,
           customer_id: event.customer_id,
           metadata_user_id: event.metadata_user_id
         }) do
      nil ->
        Logger.warning("Captured invoice with no resolvable owner",
          stripe_invoice_id: event.id,
          subscription_id: event.subscription_id,
          customer_id: event.customer_id
        )

        nil

      user_id ->
        user_id
    end
  end

  @doc """
  Coordinates a successful subscription-invoice payment by creating the
  transaction record for that billing cycle.

  A subscription's first invoice (`billing_reason: "subscription_create"`)
  is already backed by the transaction `checkout.session.completed` created
  — there is nothing to create here. Every later invoice starts a fresh
  transaction row for that billing cycle.
  """
  @spec coordinate_renewal(InvoiceEvent.t()) ::
          {:ok, PaymentTransaction.t() | :already_processed} | {:error, any()}
  def coordinate_renewal(%InvoiceEvent{billing_reason: @subscription_create} = event) do
    Logger.info("Subscription's first invoice is already backed by its checkout session",
      subscription_id: event.subscription_id,
      stripe_id: event.id
    )

    {:ok, :already_processed}
  end

  def coordinate_renewal(%InvoiceEvent{} = event) do
    Logger.info("Processing subscription renewal", subscription_id: event.subscription_id)

    with {:ok, transaction} <-
           PaymentQueries.get_active_subscription_transaction_by_subscription_id(
             event.subscription_id
           ) do
      transaction
      |> renewal_attrs(event)
      |> PaymentQueries.create_transaction()
      |> handle_duplicate_renewal(event)
    end
  end

  defp renewal_attrs(transaction, event) do
    %{
      user_id: transaction.user_id,
      amount: event.amount_paid || transaction.amount,
      status: "completed",
      # Use the invoice ID as the stripe_id for this transaction
      stripe_id: event.id,
      stripe_customer_id: transaction.stripe_customer_id,
      product_identifier: transaction.product_identifier,
      subscription_id: event.subscription_id,
      metadata:
        Map.merge(transaction.metadata, %{
          renewal_invoice_id: event.id,
          renewal_date: event.created,
          original_transaction_id: transaction.id
        })
    }
  end

  defp handle_duplicate_renewal({:ok, transaction}, _event), do: {:ok, transaction}

  defp handle_duplicate_renewal({:error, %Ecto.Changeset{} = changeset}, event) do
    if duplicate_stripe_id_error?(changeset) do
      Logger.info("Subscription renewal already processed",
        subscription_id: event.subscription_id,
        stripe_id: event.id
      )

      {:ok, :already_processed}
    else
      {:error, changeset}
    end
  end

  defp duplicate_stripe_id_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:stripe_id, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other_error -> false
    end)
  end
end
