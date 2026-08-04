defmodule Tymeslot.Payments.SubscriptionInvoiceQueries do
  @moduledoc """
  Database queries for captured Stripe subscription invoices.
  """
  import Ecto.Query

  alias Tymeslot.Payments.SubscriptionInvoiceSchema, as: SubscriptionInvoice
  alias Tymeslot.Repo

  @default_limit 24

  @doc """
  Inserts an invoice, or merges into it if one with the same
  `stripe_invoice_id` already exists.

  `invoice.finalized` and `invoice.paid` land for the same invoice in either
  order, and either may carry a field the other doesn't (the document's
  number and PDF URL only exist once finalised; the confirmed total only
  once paid), so this is an upsert rather than a plain insert. Every field is
  `COALESCE`d against the row already on disk, preferring the incoming value
  but falling back to the existing one — so a field this event doesn't carry
  can never blank a value an earlier event already captured, and `user_id`
  can still be filled in later if the first capture couldn't resolve it yet.

  `status` is the one exception to the `COALESCE` rule: Stripe includes it on
  every invoice payload, and it must be free to move sideways through the
  values Stripe itself reports (`open` -> `void`, `open` ->
  `uncollectible`, `uncollectible` -> `paid`), not just forward to `paid` —
  a `COALESCE` would only ever overwrite a `nil`. It is written from
  `EXCLUDED` with one guard: a row that already reached a settled status
  (`paid`, `void`, `uncollectible`) is never dragged back to `draft` or
  `open`. Stripe delivers webhooks at least once and in no guaranteed order,
  so `invoice.finalized` (carrying `open`) can be redelivered, or simply
  commit, after `invoice.paid` — and nothing later would correct the row,
  because a paid invoice generates no further events. Since `list_for_user/2`
  lists paid invoices only, that regression silently withdraws a VAT receipt
  the customer already had. None of the guarded transitions exist at Stripe:
  a paid invoice cannot be voided, and neither a void nor an uncollectible
  one reopens.

  `paid_at` stays `COALESCE`d like the rest of the row: it is only ever set
  once, and a later status change must not erase the historical fact that
  the invoice was paid at that moment.
  """
  @spec upsert(map()) :: {:ok, SubscriptionInvoice.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    %SubscriptionInvoice{}
    |> SubscriptionInvoice.changeset(attrs)
    |> Repo.insert(
      on_conflict: on_conflict_query(),
      conflict_target: :stripe_invoice_id,
      returning: true
    )
  end

  defp on_conflict_query do
    now = DateTime.utc_now(:second)

    from(pi in SubscriptionInvoice,
      update: [
        set: [
          # Once a row is anonymised (host_deleted_at set), a later Stripe
          # redelivery must never re-link it: keep user_id nil regardless of
          # what EXCLUDED carries, instead of relying solely on the FK
          # (which only prevents this because the deleted user's row is
          # gone, not because we intended it to).
          user_id:
            fragment(
              "CASE WHEN ? IS NOT NULL THEN NULL ELSE COALESCE(EXCLUDED.user_id, ?) END",
              pi.host_deleted_at,
              pi.user_id
            ),
          subscription_id: fragment("COALESCE(EXCLUDED.subscription_id, ?)", pi.subscription_id),
          number: fragment("COALESCE(EXCLUDED.number, ?)", pi.number),
          currency: fragment("COALESCE(EXCLUDED.currency, ?)", pi.currency),
          amount_cents: fragment("COALESCE(EXCLUDED.amount_cents, ?)", pi.amount_cents),
          issued_at: fragment("COALESCE(EXCLUDED.issued_at, ?)", pi.issued_at),
          hosted_invoice_url:
            fragment("COALESCE(EXCLUDED.hosted_invoice_url, ?)", pi.hosted_invoice_url),
          invoice_pdf_url: fragment("COALESCE(EXCLUDED.invoice_pdf_url, ?)", pi.invoice_pdf_url),
          status:
            fragment(
              """
              CASE
                WHEN ? IN ('paid', 'void', 'uncollectible')
                     AND EXCLUDED.status IN ('draft', 'open') THEN ?
                ELSE COALESCE(EXCLUDED.status, ?)
              END
              """,
              pi.status,
              pi.status,
              pi.status
            ),
          paid_at: fragment("COALESCE(EXCLUDED.paid_at, ?)", pi.paid_at),
          updated_at: ^now
        ]
      ]
    )
  end

  @doc """
  Lists a user's captured invoices that are actually paid, newest first.

  A row is captured as soon as Stripe finalises an invoice, before payment
  is even attempted, so mere presence is not "invoiced" from the customer's
  point of view: an `open` invoice awaiting a retried card charge, or one
  that ended up `void`/`uncollectible`, is not a receipt and must never be
  offered as one for VAT reclaim. `status == :paid` is the one deliberate
  definition of "listable" this function uses; every other status is
  captured (ownership resolution, anonymisation and the audit trail all
  still apply to it) but never surfaced here.
  """
  @spec list_for_user(pos_integer(), pos_integer()) :: [SubscriptionInvoice.t()]
  def list_for_user(user_id, limit \\ @default_limit) do
    query =
      from(pi in SubscriptionInvoice,
        where: pi.user_id == ^user_id and pi.status == :paid,
        order_by: [desc_nulls_last: pi.issued_at, desc: pi.id],
        limit: ^limit
      )

    Repo.all(query)
  end

  @doc """
  Nilifies `user_id` and stamps `host_deleted_at` on every invoice captured
  for a host being deleted.

  Mirrors `PaymentQueries.anonymise_for_host/2`: called in the same
  transaction, before the user row is removed, so the FK's `on_delete:
  :nilify_all` is a safety net rather than the primary mechanism. Guarded by
  `is_nil(host_deleted_at)` so re-running is a no-op on already-anonymised
  rows.

  Unlike `payment_transactions`, this does *not* fully sever the identifying
  link: `subscription_id`, `hosted_invoice_url` and `invoice_pdf_url` are
  retained deliberately.

    * `hosted_invoice_url`/`invoice_pdf_url` are the entire user-facing value
      of the row — they *are* the VAT document Stripe hosts. Scrubbing them
      would leave a retained record with nothing left to retain it for.
    * `subscription_id` is needed to explain, on the retained document
      itself, which subscription it billed; it is not host PII by itself
      (it identifies a subscription, not a person).

  This means the counterparty's name, email and billing address remain
  reachable via the Stripe-hosted document and via `subscriptions` (a SaaS
  table keyed on `stripe_customer_id`, outside Core's ownership) for as long
  as commercial law requires the record kept — the same retention rationale
  that keeps the row itself instead of deleting it. `host_deleted_at` is the
  marker of record for "this host's account no longer exists"; treat it, not
  `user_id`, as the source of truth for anonymisation state.
  """
  @spec anonymise_for_host(integer(), DateTime.t()) :: {non_neg_integer(), nil}
  def anonymise_for_host(user_id, now) do
    SubscriptionInvoice
    |> where([pi], pi.user_id == ^user_id and is_nil(pi.host_deleted_at))
    |> Repo.update_all(set: [user_id: nil, host_deleted_at: now, updated_at: now])
  end
end
