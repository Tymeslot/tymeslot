defmodule Tymeslot.Repo.Migrations.AddRequiresApprovalToMeetingTypes do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # The default is a constant, which PostgreSQL 11 and later store in the
  # catalogue rather than rewriting the table for. Tymeslot also deploys as a
  # single instance and migrates with the app stopped, so the brief catalogue
  # lock is acceptable either way.

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # The constraint covers a column added in this same migration, so every
  # existing row is NULL and satisfies `IS NULL OR …` — the validation scan
  # cannot fail. Migrations run offline: `start.sh` executes them in a
  # one-shot VM and only starts Phoenix once they finish, so the ACCESS
  # EXCLUSIVE lock blocks no traffic.

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

    create(
      constraint(:meeting_types, :meeting_types_approval_window_hours_range,
        check: "approval_window_hours IS NULL OR (approval_window_hours BETWEEN 1 AND 336)"
      )
    )
  end
end
