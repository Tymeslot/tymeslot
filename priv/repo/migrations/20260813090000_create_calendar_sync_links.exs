defmodule Tymeslot.Repo.Migrations.CreateCalendarSyncLinks do
  use Ecto.Migration

  # Both assurances apply because the table is created empty in this same
  # migration: there are no rows for the unique index to lock out, and both
  # references are declared as part of CREATE TABLE rather than added to a
  # table already holding data, so nothing a running deploy reads is locked.
  # Building the index concurrently is not possible here in any case, since
  # CREATE INDEX CONCURRENTLY cannot run inside the transaction a migration
  # runs in.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # A check constraint added to a populated table takes an ACCESS EXCLUSIVE
  # lock while every existing row is validated. This one is added to a table
  # created empty three statements earlier, so there is nothing to validate and
  # nothing else can hold a reference to the table yet.
  # excellent_migrations:safety-assured-for-this-file check_constraint_added

  # One row per configured mirroring relationship: events on the source
  # integration get a placeholder written onto the target so external tools
  # booking against the target see the time as taken.
  #
  # Direction is modelled by rows, not by a `direction` column. A bidirectional
  # relationship is two rows. That keeps every row a single unambiguous
  # source→target statement, makes "pause one direction" expressible through
  # `enabled`, and avoids a column whose two values would each need a different
  # reading of which integration is which.
  #
  # `user_id` is denormalised from the two integrations so the dashboard can
  # list an organiser's links without joining both sides, and so a link
  # survives no orphan window: deleting either integration cascades the row
  # away, and deleting the user cascades it away too.
  def change do
    create table(:calendar_sync_links) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      add(:source_integration_id, references(:calendar_integrations, on_delete: :delete_all),
        null: false
      )

      add(:target_integration_id, references(:calendar_integrations, on_delete: :delete_all),
        null: false
      )

      # nil means the target's primary calendar. The CalDAV family ignores a
      # calendar id on write and always lands on the primary path, so for those
      # providers the column is forced nil rather than left to mislead.
      add(:target_calendar_id, :string)

      add(:privacy_tier, :string, null: false, default: "busy_only")
      add(:generic_label, :string)
      add(:mirror_colour, :string)

      # Pausing rather than deleting: a deleted link tears its mirrors down,
      # which means re-enabling costs a full rewrite against the provider.
      add(:enabled, :boolean, null: false, default: true)

      add(:last_reconciled_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    # Named explicitly: the derived name exceeds Postgres' 63-character
    # identifier limit and would be silently truncated, leaving the index under
    # a name no later migration could predict in order to drop it.
    #
    # `nulls_distinct: false` is load-bearing, not a refinement. Postgres treats
    # NULLs as distinct by default, so without it the index would permit two
    # identical links whenever `target_calendar_id` is nil — and nil is not the
    # edge case here but the norm: every CalDAV-family target has the column
    # forced nil, because those providers ignore a calendar id on write. The
    # default behaviour would therefore leave the seven CalDAV providers with no
    # uniqueness guarantee at all, and a duplicate link means every source event
    # mirrored twice onto the same calendar.
    create(
      unique_index(
        :calendar_sync_links,
        [:source_integration_id, :target_integration_id, :target_calendar_id],
        name: :calendar_sync_links_source_target_calendar_index,
        nulls_distinct: false
      )
    )

    # Listing an organiser's links is the dashboard's only read path.
    create(index(:calendar_sync_links, [:user_id], name: :calendar_sync_links_user_id_index))

    # A link from an integration to itself would mirror every event back onto
    # the calendar it came from. The changeset rejects it, but the changeset is
    # bypassable by any future direct insert, and the failure mode — an endless
    # self-mirroring calendar — is bad enough to be worth the constraint.
    create(
      constraint(:calendar_sync_links, :calendar_sync_links_no_self_link,
        check: "source_integration_id <> target_integration_id"
      )
    )
  end
end
