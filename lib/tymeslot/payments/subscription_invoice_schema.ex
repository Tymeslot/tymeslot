defmodule Tymeslot.Payments.SubscriptionInvoiceSchema do
  @moduledoc """
  Schema for a captured Stripe subscription invoice.

  Keyed on `stripe_invoice_id`, the invoice's own identity, independently of
  any `payment_transactions` row. `user_id` is nullable because the row must
  still be retained (and thus survive a host account being deleted) as a VAT
  document. `host_deleted_at` marks that retention explicitly; see
  `SubscriptionInvoiceQueries.anonymise_for_host/2` for what is and isn't
  scrubbed when it is set.

  This table covers *platform subscription* invoices only (billed by
  Tymeslot to the host). It deliberately does not cover Connect direct-charge
  booking invoices (billed by the host to their attendee, via
  `invoice_creation` on the Connect checkout session — see
  `MeetingPayments.CheckoutSessions`): those have a different issuer, a
  different tax entity, and inverted owner semantics, and Stripe already
  hosts and emails them to the attendee directly, so there is nothing here
  to capture them for.

  `status` mirrors Stripe's own invoice status verbatim, so it can converge
  through the same values Stripe itself uses (`open` -> `paid`, `open` ->
  `void`, `open` -> `uncollectible`) as later events arrive for the same
  invoice; see `SubscriptionInvoiceQueries.upsert/1` for why this field is
  set unconditionally rather than `COALESCE`d like the rest of the row.
  `paid_at` is captured alongside it, from `status_transitions.paid_at`.

  `hosted_invoice_url` and `invoice_pdf_url` are unauthenticated Stripe
  capability links (anyone holding one can view or pay the invoice), so both
  are marked `redact: true`: struct field access is unaffected, but an
  incidental `inspect/1` of the schema or a changeset built from it can never
  leak either URL into logs.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema

  @statuses [:draft, :open, :paid, :void, :uncollectible]

  @type t :: %__MODULE__{
          id: integer() | nil,
          stripe_invoice_id: String.t() | nil,
          user_id: integer() | nil,
          subscription_id: String.t() | nil,
          number: String.t() | nil,
          currency: String.t() | nil,
          amount_cents: integer() | nil,
          issued_at: DateTime.t() | nil,
          hosted_invoice_url: String.t() | nil,
          invoice_pdf_url: String.t() | nil,
          host_deleted_at: DateTime.t() | nil,
          status: :draft | :open | :paid | :void | :uncollectible | nil,
          paid_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "subscription_invoices" do
    field :stripe_invoice_id, :string
    belongs_to :user, UserSchema
    field :subscription_id, :string
    field :number, :string
    field :currency, :string
    field :amount_cents, :integer
    field :issued_at, :utc_datetime
    field :hosted_invoice_url, :string, redact: true
    field :invoice_pdf_url, :string, redact: true

    # Set once the invoice is anonymised for a deleted host; nil otherwise.
    field :host_deleted_at, :utc_datetime

    field :status, Ecto.Enum, values: @statuses
    field :paid_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for capturing (inserting or upserting) an invoice.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [
      :stripe_invoice_id,
      :user_id,
      :subscription_id,
      :number,
      :currency,
      :amount_cents,
      :issued_at,
      :hosted_invoice_url,
      :invoice_pdf_url,
      :host_deleted_at,
      :status,
      :paid_at
    ])
    |> validate_required([:stripe_invoice_id])
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:stripe_invoice_id)
  end
end
