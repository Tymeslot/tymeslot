defmodule Tymeslot.Migrations.AddEmailVerificationToMeetingParticipantsTest do
  @moduledoc """
  Covers `20261113160147_add_email_verification_to_meeting_participants`,
  which adds the verification columns to seats and the partial index the
  expiry sweep reads.

  Outside the sandbox, necessarily: the migration disables the DDL transaction
  so its concurrent build can run at all. The rows it seeds are deleted
  afterwards and the migration put back on the ledger. Tagged `:migrations`,
  which no default run includes: run it with `mix test --only migrations`.
  """

  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :bookings

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_113_160_147
  @index "meeting_participants_unverified_deadline_index"
  @email "organizer@participant-verification-migration.test"

  setup do
    check_out!()

    on_exit(fn ->
      check_out!()
      Repo.query!("DELETE FROM users WHERE email = $1", [@email])

      Migrator.up(Repo, @version, MigrationRunner.module(@version),
        migration_lock: false,
        log: false
      )
    end)

    :ok
  end

  describe "up" do
    test "a seat inserts with both columns, and the index serves the sweep" do
      MigrationRunner.rerun!(@version)

      meeting_id = insert_meeting!()

      Repo.query!(
        """
        INSERT INTO meeting_participants (id, meeting_id, name, email, timezone, locale,
          ical_sequence, custom_field_answers, management_token_hash,
          verification_deadline_at, email_verified_at, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, 'Ada', 'ada@example.com', 'Europe/London', 'en', 0,
          '{}', 'hash-verification-migration', NOW(), NOW(), NOW(), NOW())
        """,
        [meeting_id]
      )

      assert definition(@index) =~ "verification_deadline_at"
      assert definition(@index) =~ "email_verified_at IS NULL"
      assert definition(@index) =~ "cancelled_at IS NULL"
    end

    test "re-running is a no-op" do
      MigrationRunner.rerun!(@version)
      %{rows: [[before]]} = Repo.query!("SELECT to_regclass($1)::oid", [@index])

      MigrationRunner.replay!(@version)

      assert %{rows: [[^before]]} = Repo.query!("SELECT to_regclass($1)::oid", [@index])
    end

    # The state an interrupted `CREATE INDEX CONCURRENTLY` leaves behind,
    # reached by writing the catalogue: no data can make this build fail.
    test "an invalid index is dropped and built again" do
      MigrationRunner.rerun!(@version)

      Repo.query!("UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1)", [
        @index
      ])

      %{rows: [[invalid_oid]]} = Repo.query!("SELECT to_regclass($1)::oid", [@index])

      MigrationRunner.replay!(@version)

      assert %{rows: [[true]]} =
               Repo.query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [
                 @index
               ])

      refute %{rows: [[invalid_oid]]} == Repo.query!("SELECT to_regclass($1)::oid", [@index])
    end
  end

  describe "down" do
    test "removes the columns and the index" do
      MigrationRunner.down!(@version)

      assert definition(@index) == nil

      assert %{rows: []} =
               Repo.query!(
                 "SELECT 1 FROM information_schema.columns WHERE table_name = " <>
                   "'meeting_participants' AND column_name IN " <>
                   "('verification_deadline_at', 'email_verified_at')"
               )
    end
  end

  defp insert_meeting! do
    %{rows: [[user_id]]} =
      Repo.query!(
        "INSERT INTO users (email, inserted_at, updated_at) VALUES ($1, NOW(), NOW()) RETURNING id",
        [@email]
      )

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO meetings (id, uid, calendar_uid, title, start_time, end_time, organizer_name,
          organizer_email, attendee_name, attendee_email, organizer_user_id, status,
          inserted_at, updated_at)
        VALUES (gen_random_uuid(), gen_random_uuid()::text, gen_random_uuid()::text, 'Seat test',
          '2030-01-06 10:00:00', '2030-01-06 10:30:00', 'Organizer', $1, 'Attendee',
          'attendee@example.com', $2, 'confirmed', NOW(), NOW())
        RETURNING id
        """,
        [@email, user_id]
      )

    id
  end

  defp definition(index) do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [index]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp check_out! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
