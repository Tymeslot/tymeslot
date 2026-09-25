defmodule Tymeslot.Migrations.ExcludeVoidedSlotsFromMeetingUniqueIndexTest do
  @moduledoc """
  Covers `20260916121726_exclude_voided_slots_from_meeting_unique_index`,
  which swaps the predicate of `unique_confirmed_meeting_per_organizer_at_time`
  without ever leaving `meetings` unguarded.

  The property under test is the order of operations: the replacement is built
  under a staging name before the old index is dropped, and a build that
  cannot succeed (duplicate rows under the target predicate) is skipped with a
  warning rather than failing the boot. Run against the drop-first form, the
  duplicate tests fail with a raised unique violation and the swap tests still
  pass, which is exactly the asymmetry the staging exists to close.

  Outside the sandbox, necessarily: the migration disables the DDL transaction
  so its concurrent builds can run at all. The rows it seeds are deleted and
  the index put back from its captured definition afterwards, whatever a test
  did to it. Tagged `:migrations`, which no default run includes: run it with
  `mix test --only migrations`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :database
  @moduletag :migrations

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_916_121_726

  @index "unique_confirmed_meeting_per_organizer_at_time"
  @staging "unique_confirmed_meeting_per_organizer_at_time_new"

  @organizer_email "organizer@exclude-voided-slots-migration.test"
  @slot ~N[2030-01-06 10:00:00]

  setup do
    check_out!()
    original = definition(@index)
    assert original =~ "reschedule_requested_at IS NULL"
    organizer_id = insert_organizer!()

    on_exit(fn ->
      check_out!()
      Repo.query!("DELETE FROM users WHERE email = $1", [@organizer_email])
      Repo.query!("DROP INDEX IF EXISTS #{@staging}")

      unless index_valid?(@index) and definition(@index) == original do
        Repo.query!("DROP INDEX IF EXISTS #{@index}")
        Repo.query!(original)
      end

      # A test that ran `down/0` left the version off the ledger; putting it
      # back through the migrator is a no-op against the restored index.
      Migrator.up(Repo, @version, MigrationRunner.module(@version),
        migration_lock: false,
        log: false
      )
    end)

    %{organizer_id: organizer_id, original: original}
  end

  describe "up" do
    test "swaps in the narrower predicate and leaves no staging index behind" do
      MigrationRunner.rerun!(@version)

      assert index_valid?(@index)
      assert definition(@index) =~ "CREATE UNIQUE INDEX"
      assert definition(@index) =~ "reschedule_requested_at IS NULL"
      assert definition(@staging) == nil
    end

    # A run interrupted after the rename, or a database restored from a
    # migrated dump, already has the target index. Rebuilding it would cost a
    # concurrent build of the whole table for nothing; a rebuilt index gets a
    # new OID, a skipped one keeps its own.
    test "does nothing when the index already has the target predicate" do
      before = index_oid(@index)

      MigrationRunner.replay!(@version)

      assert index_oid(@index) == before
    end

    # The state an interrupted `20260902120100` leaves behind: an index of that
    # name enforcing nothing, and unguarded inserts since. Drop-first would
    # remove it, fail the build over the duplicates, and crash-loop the boot.
    test "warns and keeps an invalid index in place when duplicates exist", %{
      organizer_id: organizer_id
    } do
      Repo.query!("DROP INDEX #{@index}")
      Repo.query!("CREATE INDEX #{@index} ON meetings (organizer_user_id, start_time)")
      mark_invalid!(@index)
      insert_meeting!(organizer_id, "confirmed", nil)
      insert_meeting!(organizer_id, "confirmed", nil)
      before = index_oid(@index)

      log = capture_log(fn -> MigrationRunner.replay!(@version) end)

      assert log =~ "Leaving index #{@index} as it is: meetings holds 2 rows"
      assert log =~ "CREATE UNIQUE INDEX CONCURRENTLY #{@index}"
      assert index_oid(@index) == before
      refute index_valid?(@index)
      assert definition(@staging) == nil
    end

    test "replaces a staging index an interrupted run left invalid" do
      Repo.query!("CREATE INDEX #{@staging} ON meetings (organizer_user_id)")
      mark_invalid!(@staging)

      MigrationRunner.rerun!(@version)

      assert index_valid?(@index)
      assert definition(@index) =~ "reschedule_requested_at IS NULL"
      assert definition(@staging) == nil
    end
  end

  describe "down" do
    test "restores the wider predicate" do
      MigrationRunner.down!(@version)

      assert index_valid?(@index)
      assert definition(@index) =~ "CREATE UNIQUE INDEX"
      assert definition(@index) =~ "awaiting_approval"
      refute definition(@index) =~ "reschedule_requested_at"
      assert definition(@staging) == nil
    end

    # A voided slot that has since been rebooked: two confirmed rows on one
    # slot, which the current index allows and the wider one would not. A
    # rollback must not cancel either booking to make room.
    test "warns and keeps the current index when a voided slot has been rebooked", %{
      organizer_id: organizer_id,
      original: original
    } do
      insert_meeting!(organizer_id, "confirmed", ~N[2030-01-01 09:00:00])
      insert_meeting!(organizer_id, "confirmed", nil)
      before = index_oid(@index)

      log = capture_log(fn -> MigrationRunner.down!(@version) end)

      assert log =~ "Leaving index #{@index} as it is: meetings holds 2 rows"
      assert index_oid(@index) == before
      assert definition(@index) == original
      assert definition(@staging) == nil
    end
  end

  defp insert_organizer! do
    %{rows: [[id]]} =
      Repo.query!(
        "INSERT INTO users (email, inserted_at, updated_at) VALUES ($1, NOW(), NOW()) " <>
          "RETURNING id",
        [@organizer_email]
      )

    id
  end

  # Every row lands on the same organizer and start time, so two of them form
  # a duplicate under whichever predicate admits both.
  defp insert_meeting!(organizer_id, status, reschedule_requested_at) do
    Repo.query!(
      """
      INSERT INTO meetings (id, uid, title, start_time, end_time, organizer_name,
        organizer_email, attendee_name, attendee_email, organizer_user_id, status,
        reschedule_requested_at, inserted_at, updated_at)
      VALUES (gen_random_uuid(), gen_random_uuid()::text, 'Voided slot test', $1, $2,
        'Organizer', $3, 'Attendee', 'attendee@example.com', $4, $5, $6, NOW(), NOW())
      """,
      [
        @slot,
        NaiveDateTime.add(@slot, 30, :minute),
        @organizer_email,
        organizer_id,
        status,
        reschedule_requested_at
      ]
    )
  end

  # The state an interrupted `CREATE INDEX CONCURRENTLY` leaves behind.
  defp mark_invalid!(index) do
    Repo.query!("UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1)", [
      index
    ])
  end

  defp index_valid?(index) do
    case Repo.query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [
           index
         ]) do
      %{rows: [[valid]]} -> valid
      %{rows: []} -> false
    end
  end

  defp definition(index) do
    case Repo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [index]) do
      %{rows: [[definition]]} -> definition
      %{rows: []} -> nil
    end
  end

  defp index_oid(index) do
    %{rows: [[oid]]} = Repo.query!("SELECT to_regclass($1)::oid", [index])
    oid
  end

  defp check_out! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
