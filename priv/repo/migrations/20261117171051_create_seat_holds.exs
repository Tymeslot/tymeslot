defmodule Tymeslot.Repo.Migrations.CreateSeatHolds do
  @moduledoc """
  A booker who has not paid yet for a seat on a paid group meeting is a
  `seat_holds` row, never a `meeting_participants` row. A live hold
  (`status = 'held'`) counts against the meeting's capacity, guests included,
  and lasts as long as its Stripe Checkout session (30 minutes). When the
  payment completes the hold is converted into an ordinary participant.

  The hold snapshots the participant fields so the participant can be created
  from it later, and keeps its guests as a list of `{"name", "email"}` maps
  (`name` is nil today). `custom_field_answers` is personal data.

  `participant_id` is `nilify_all`, so there is deliberately no database check
  tying a converted hold to a participant.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # The table is created in this same migration. It is empty and unreachable
  # until the migration commits, so its indexes and check constraints validate
  # no row and block no reader.

  def change do
    create table(:seat_holds, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all),
        null: false

      add :meeting_type_id, references(:meeting_types, on_delete: :nilify_all)
      add :start_time, :utc_datetime, null: false
      add :seats, :integer, null: false
      add :status, :string, null: false, default: "held"
      add :released_reason, :string
      add :expires_at, :utc_datetime, null: false
      add :name, :string, null: false
      add :email, :string, null: false
      add :phone, :string
      add :company, :string
      add :message, :text
      add :timezone, :string
      add :locale, :string, null: false, default: "en"
      add :custom_field_answers, :map, null: false, default: %{}
      # list of %{"name" => nil | String.t(), "email" => String.t()}
      add :guests, :jsonb, null: false, default: "[]"

      add :participant_id,
          references(:meeting_participants, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create constraint(:seat_holds, :seat_holds_seats_positive, check: "seats >= 1")

    create constraint(:seat_holds, :seat_holds_status_must_be_known,
             check: "status IN ('held', 'converted', 'released')"
           )

    create constraint(:seat_holds, :seat_holds_released_reason_must_be_known,
             check:
               "released_reason IS NULL OR released_reason IN ('expired', 'failed', 'abandoned', 'meeting_cancelled')"
           )

    create constraint(:seat_holds, :seat_holds_released_has_reason,
             check: "(status = 'released') = (released_reason IS NOT NULL)"
           )

    create unique_index(:seat_holds, ["meeting_id", "lower(email)"],
             where: "status = 'held'",
             name: :seat_holds_live_email_index
           )

    create index(:seat_holds, [:status, :expires_at], name: :seat_holds_status_expires_at_index)
    create index(:seat_holds, [:meeting_id], name: :seat_holds_meeting_id_index)
  end
end
