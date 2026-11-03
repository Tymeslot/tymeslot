defmodule Tymeslot.Repo.Migrations.AddDisputeTrackingToBookingPayments do
  @moduledoc """
  Records which Stripe dispute a booking payment last saw, and when that
  dispute closed, so a `charge.dispute.created` delivered after its own
  `charge.dispute.closed` can be recognised and ignored rather than
  reopening a settled dispute. Both columns are nullable and start empty:
  existing rows have recorded no dispute, which is how the handlers already
  treated them.
  """

  use Ecto.Migration

  def change do
    alter table(:booking_payments) do
      add :stripe_dispute_id, :string
      add :dispute_closed_at, :utc_datetime
    end
  end
end
