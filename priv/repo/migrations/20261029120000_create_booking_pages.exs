defmodule Tymeslot.Repo.Migrations.CreateBookingPages do
  @moduledoc """
  Booking pages: extra public start pages of a profile, each at its own
  top-level address with its own theme, texts and meeting types, beside the
  profile's own page at `/<username>`.

  Adds `booking_pages` and `booking_page_meeting_types`, and a nullable
  `booking_page_id` on `theme_customizations` (a page's own colours) and on
  `meetings` (the page a booking came through). Existing customisation rows
  keep a NULL page id and stay the profile's, so the unique index on
  `(profile_id, theme_id)` becomes partial, admitting one row per page beside
  them.
  """

  use Ecto.Migration

  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so no request waits on these locks.
  # Both new reference columns are added in the statement that creates their
  # foreign key, so every existing row is NULL and nothing needs validating.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  #
  # The deduplication guard and the rollback's cleanup are single set-based
  # statements.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # `down/0` removes only what `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file table_dropped

  def up do
    create table(:booking_pages) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :booking_theme, :string, null: false
      add :booking_text_enabled, :boolean, null: false, default: false
      add :booking_heading, :string
      add :booking_greeting, :string
      add :booking_instruction, :string

      timestamps(type: :utc_datetime)
    end

    create index(:booking_pages, [:profile_id])
    create unique_index(:booking_pages, ["lower(slug)"], name: :booking_pages_slug_index)

    create table(:booking_page_meeting_types) do
      add :booking_page_id, references(:booking_pages, on_delete: :delete_all), null: false
      add :meeting_type_id, references(:meeting_types, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:booking_page_meeting_types, [:booking_page_id, :meeting_type_id])
    create index(:booking_page_meeting_types, [:meeting_type_id])

    alter table(:theme_customizations) do
      add :booking_page_id, references(:booking_pages, on_delete: :delete_all)
    end

    # Every existing row already satisfies the partial index below, since the
    # full index it replaces was stricter. This guards a database that arrived
    # here without that index (a restore, a hand-dropped index), keeping the
    # most recently updated row per profile and theme.
    execute("""
    DELETE FROM theme_customizations t
    USING theme_customizations keep
    WHERE t.booking_page_id IS NULL
      AND keep.booking_page_id IS NULL
      AND t.profile_id = keep.profile_id
      AND t.theme_id = keep.theme_id
      AND (t.updated_at, t.id) < (keep.updated_at, keep.id)
    """)

    drop_if_exists unique_index(:theme_customizations, [:profile_id, :theme_id])

    # Same name as the index it replaces, so `unique_constraint([:profile_id,
    # :theme_id])` in the schema keeps matching.
    create unique_index(:theme_customizations, [:profile_id, :theme_id],
             where: "booking_page_id IS NULL",
             name: :theme_customizations_profile_id_theme_id_index
           )

    create unique_index(:theme_customizations, [:booking_page_id, :theme_id])

    alter table(:meetings) do
      add :booking_page_id, references(:booking_pages, on_delete: :nilify_all)
    end

    # Partial: only bookings made through a page carry an id, and the index
    # exists so deleting a page finds them without scanning every meeting.
    create index(:meetings, [:booking_page_id], where: "booking_page_id IS NOT NULL")
  end

  def down do
    drop_if_exists index(:meetings, [:booking_page_id])

    alter table(:meetings) do
      remove :booking_page_id
    end

    drop_if_exists unique_index(:theme_customizations, [:booking_page_id, :theme_id])

    drop_if_exists unique_index(:theme_customizations, [:profile_id, :theme_id],
                     name: :theme_customizations_profile_id_theme_id_index
                   )

    # A page's rows would collide with the profile's once the full index is
    # back, and they mean nothing without their page.
    execute("DELETE FROM theme_customizations WHERE booking_page_id IS NOT NULL")

    alter table(:theme_customizations) do
      remove :booking_page_id
    end

    create unique_index(:theme_customizations, [:profile_id, :theme_id])

    drop table(:booking_page_meeting_types)
    drop table(:booking_pages)
  end
end
