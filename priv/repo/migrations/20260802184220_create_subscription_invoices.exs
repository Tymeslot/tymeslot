defmodule Tymeslot.Repo.Migrations.CreateSubscriptionInvoices do
  @moduledoc """
  An invoice is not an attribute of a payment transaction: Stripe finalises
  every subscription invoice independently of whether the transaction row
  it will eventually relate to exists yet, so "which row does this invoice
  belong to?" cannot be answered by a heuristic scoped to another table's
  identity. This table gives an invoice its own identity instead
  (`stripe_invoice_id`, unique), captured as an upsert so `invoice.finalized`
  and `invoice.paid` converge on one row regardless of delivery order, and
  so an invoice with no matching transaction is still captured. Ownership
  (`user_id`) is resolved via `Payments.CustomerLookup.find_user_id/1`
  against the Stripe customer/subscription, never against this table's own
  `payment_transactions` rows.

  Named `subscription_invoices`, not `payment_invoices` or `invoices`: it
  covers platform subscription invoices only. Connect direct-charge booking
  invoices (`MeetingPayments.CheckoutSessions`) are a different table
  entirely — different issuer, different tax entity, inverted owner
  semantics — and are deliberately not captured anywhere, since Stripe
  already hosts and emails them to the attendee directly.

  `user_id` is nullable, mirroring `payment_transactions.user_id`'s
  `:nilify_all` retention design: an invoice is a VAT document, kept as a
  tax record after a host account is deleted.

  `amount_cents` and `issued_at` are captured from the invoice payload
  itself (`total` and `status_transitions.finalized_at`), not derived from
  any transaction, so the values a customer sees always agree with the
  Stripe-hosted document behind the link.

  `host_deleted_at` mirrors `payment_transactions.host_deleted_at`: it marks
  a row as anonymised, distinguishing "owner deleted their account" from "we
  never resolved an owner for this invoice". `subscription_id`,
  `hosted_invoice_url` and `invoice_pdf_url` are deliberately retained past
  anonymisation rather than scrubbed — see `SubscriptionInvoiceQueries` for
  why.

  `status` mirrors Stripe's own invoice status (`draft | open | paid | void |
  uncollectible`) so a listing query can tell a paid receipt from an unpaid
  or voided document — see `SubscriptionInvoiceQueries.list_for_user/2`.
  `paid_at` is captured from `status_transitions.paid_at` alongside it.
  """
  # The reference and the two indexes below are all created against a table
  # this same migration creates: it holds no rows yet, so there is no lock
  # contention or table rewrite to avoid by adding them concurrently or in a
  # later migration.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  use Ecto.Migration

  def change do
    create table(:subscription_invoices) do
      add(:stripe_invoice_id, :string, null: false)
      add(:user_id, references(:users, on_delete: :nilify_all))
      add(:subscription_id, :string)
      add(:number, :string)
      add(:currency, :string)
      add(:amount_cents, :integer)
      add(:issued_at, :utc_datetime)
      add(:hosted_invoice_url, :text)
      add(:invoice_pdf_url, :text)
      add(:host_deleted_at, :utc_datetime)
      add(:status, :string)
      add(:paid_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:subscription_invoices, [:stripe_invoice_id]))
    create(index(:subscription_invoices, [:user_id, :issued_at]))
  end
end
