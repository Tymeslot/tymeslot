defmodule Tymeslot.Repo.Migrations.AddKeyAttemptToBookingPaymentRefunds do
  @moduledoc """
  Records which attempt's idempotency key a refund's requests to Stripe are
  sent under. It stays the same until Stripe answers a request under it, so
  an attempt following one that got no answer sends that same key, and
  Stripe returns the refund the earlier request made instead of making a
  second one.

  Nullable, with no default: an existing row has no key in use, and its
  next attempt takes its own.
  """

  use Ecto.Migration

  def change do
    alter table(:booking_payment_refunds) do
      add :key_attempt, :integer
    end
  end
end
