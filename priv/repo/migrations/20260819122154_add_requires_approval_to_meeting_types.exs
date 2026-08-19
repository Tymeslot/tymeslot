defmodule Tymeslot.Repo.Migrations.AddRequiresApprovalToMeetingTypes do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # The default is a constant, which PostgreSQL 11 and later store in the
  # catalogue rather than rewriting the table for. Tymeslot also deploys as a
  # single instance and migrates with the app stopped, so the brief catalogue
  # lock is acceptable either way.

  # Opting a meeting type into manual approval: bookings are held rather than
  # confirmed until the host answers. `false` keeps every existing meeting type
  # behaving exactly as it does today.
  #
  # `approval_window_hours` is nullable rather than defaulted because nil means
  # "use the application default", which is the same spelling the reminder and
  # availability settings already use for "not overridden here". A value stored
  # on every row would freeze today's default into historical data.
  def change do
    alter table(:meeting_types) do
      add(:requires_approval, :boolean, null: false, default: false)
      add(:approval_window_hours, :integer)
    end
  end
end
