defmodule Tymeslot.Repo.Migrations.AddVisitorHashToMeetings do
  use Ecto.Migration

  # Cookieless join key linking a booking back to its booking-page view in
  # analytics_events. Nullable: bookings created before this migration, or
  # outside the public booking flow (admin/import/API), have no hash and are
  # simply excluded from the conversion join. No backfill is possible — the
  # daily-rotated salt for past days is gone — and none is needed.
  def change do
    alter table(:meetings) do
      add_if_not_exists(:visitor_hash, :string)
    end
  end
end
