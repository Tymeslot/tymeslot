defmodule Tymeslot.Repo.Migrations.AddPaymentFieldsToMeetingTypes do
  @moduledoc """
  Adds payment-related fields to meeting_types: payment_required, price_cents,
  is_archived. Validation is at the changeset level; no Postgres CHECK.
  """

  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add(:payment_required, :boolean, default: false, null: false)
      add(:price_cents, :bigint)
      add(:is_archived, :boolean, default: false, null: false)
    end

    create(index(:meeting_types, [:user_id, :is_archived]))
  end
end
