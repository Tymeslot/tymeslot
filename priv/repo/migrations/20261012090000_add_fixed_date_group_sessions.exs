defmodule Tymeslot.Repo.Migrations.AddFixedDateGroupSessions do
  use Ecto.Migration

  @moduledoc """
  Fixed dates for group meeting types.

  A group type can now offer the sessions its host planned instead of the
  slots its availability schedule produces (`meeting_types.fixed_dates`).
  Each session is the type's group meeting row itself, created by the host
  ahead of any booking (`meetings.planned`), with an optional time after
  which nobody can sign up any more (`meetings.registration_closes_at`).

  Every existing row gets `false` and `NULL`, and so behaves exactly as
  before. The partial index serves the one new lookup: a type's planned
  sessions in start order.
  """

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # Migrations run offline: start.sh executes them in a one-shot VM before
  # Phoenix starts, so no request contends for the locks. The defaults are
  # constants, which Postgres 11+ records in the catalogue without rewriting
  # the table, and the new index is partial over rows no existing data
  # matches.

  def change do
    alter table(:meeting_types) do
      add(:fixed_dates, :boolean, null: false, default: false)
    end

    alter table(:meetings) do
      add(:planned, :boolean, null: false, default: false)
      add(:registration_closes_at, :utc_datetime)
    end

    create(
      index(:meetings, [:meeting_type_id, :start_time],
        where: "planned",
        name: :meetings_planned_sessions_index
      )
    )
  end
end
