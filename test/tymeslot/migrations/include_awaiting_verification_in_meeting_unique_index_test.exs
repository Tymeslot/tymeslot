defmodule Tymeslot.Migrations.IncludeAwaitingVerificationInMeetingUniqueIndexTest do
  @moduledoc """
  Covers `20261112193609_include_awaiting_verification_in_meeting_unique_index`,
  which widens the predicates of `unique_confirmed_meeting_per_organizer_at_time`
  and `meetings_invitation_id_occupying_index` so a booking held for email
  verification occupies its slot, and builds the index the expiry sweep reads.

  Outside the sandbox, necessarily: the migration disables the DDL transaction
  so its concurrent builds can run at all. The rows it seeds are deleted and
  the three indexes put back from their captured definitions afterwards,
  whatever a test did to them. Tagged `:migrations`, which no default run
  includes: run it with `mix test --only migrations`.
  """

  use ExUnit.Case, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :bookings

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Migrator
  alias Ecto.UUID
  alias Tymeslot.Meetings.{MeetingSchema, UniqueSlot}
  alias Tymeslot.Repo
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_112_193_609

  @slot_index "unique_confirmed_meeting_per_organizer_at_time"
  @invitation_index "meetings_invitation_id_occupying_index"
  @sweep_index "meetings_awaiting_verification_deadline_index"
  @staged ["#{@slot_index}_new", "#{@invitation_index}_new"]

  @organizer_email "organizer@awaiting-verification-index-migration.test"
  @slot ~N[2030-01-06 10:00:00]

  setup do
    check_out!()
    originals = Map.new([@slot_index, @invitation_index, @sweep_index], &{&1, definition(&1)})
    assert originals[@slot_index] =~ "awaiting_verification"
    organizer_id = insert_organizer!()

    on_exit(fn ->
      check_out!()
      Repo.query!("DELETE FROM users WHERE email = $1", [@organizer_email])
      Enum.each(@staged, &Repo.query!("DROP INDEX IF EXISTS #{&1}"))

      for {index, original} <- originals, definition(index) != original do
        Repo.query!("DROP INDEX IF EXISTS #{index}")
        Repo.query!(original)
      end

      # A test that ran `down/0` left the version off the ledger; putting it
      # back through the migrator is a no-op against the restored indexes.
      Migrator.up(Repo, @version, MigrationRunner.module(@version),
        migration_lock: false,
        log: false
      )
    end)

    LogCapture.attach()
    %{organizer_id: organizer_id}
  end

  describe "up" do
    test "an unverified booking and a confirmed one cannot share a start time", %{
      organizer_id: organizer_id
    } do
      MigrationRunner.rerun!(@version)

      assert {:ok, _meeting} = insert_through_schema(organizer_id, :confirmed)
      assert {:error, changeset} = insert_through_schema(organizer_id, :awaiting_verification)
      assert UniqueSlot.violation?(changeset)
    end

    test "widens the invitation index and builds the sweep index" do
      MigrationRunner.rerun!(@version)

      assert definition(@invitation_index) =~ "awaiting_verification"
      assert definition(@sweep_index) =~ "verification_deadline_at"
      assert definition(@sweep_index) =~ "awaiting_verification"
      assert Enum.all?(@staged, &(definition(&1) == nil))
    end

    test "the migration is a no-op when the index is already current" do
      MigrationRunner.rerun!(@version)
      before = Enum.map([@slot_index, @invitation_index, @sweep_index], &index_oid/1)

      MigrationRunner.replay!(@version)

      assert Enum.map([@slot_index, @invitation_index, @sweep_index], &index_oid/1) == before
    end

    test "an invalid sweep index is dropped and built again" do
      mark_invalid!(@sweep_index)
      invalid_oid = index_oid(@sweep_index)

      MigrationRunner.replay!(@version)

      assert valid?(@sweep_index)
      refute index_oid(@sweep_index) == invalid_oid
      assert definition(@sweep_index) =~ "awaiting_verification"
    end

    test "duplicates leave the index as it was and warn", %{organizer_id: organizer_id} do
      Repo.query!("DROP INDEX #{@slot_index}")
      insert_meeting!(organizer_id, "confirmed")
      insert_meeting!(organizer_id, "awaiting_verification")

      MigrationRunner.replay!(@version)

      assert LogCapture.await_log("Leaving index #{@slot_index} as it is: meetings holds 2 rows")
      assert definition(@slot_index) == nil
    end
  end

  describe "down" do
    test "down restores the narrower predicate" do
      MigrationRunner.down!(@version)

      assert definition(@slot_index) =~ "CREATE UNIQUE INDEX"
      assert definition(@slot_index) =~ "awaiting_approval"
      refute definition(@slot_index) =~ "awaiting_verification"
      assert definition(@invitation_index) =~ "awaiting_approval"
      refute definition(@invitation_index) =~ "awaiting_verification"
      assert definition(@sweep_index) == nil
      assert Enum.all?(@staged, &(definition(&1) == nil))
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

  defp insert_through_schema(organizer_id, status) do
    start_time = DateTime.from_naive!(@slot, "Etc/UTC")

    %MeetingSchema{}
    |> MeetingSchema.changeset(%{
      uid: UUID.generate(),
      title: "Verification index test",
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      organizer_name: "Organizer",
      organizer_email: @organizer_email,
      attendee_name: "Attendee",
      attendee_email: "attendee@example.com",
      organizer_user_id: organizer_id,
      status: status
    })
    # A test's own fixture, inserted through the schema to probe the index.
    # excellent_migrations:safety-assured-for-next-line operation_insert
    |> Repo.insert()
  end

  # Every row lands on the same organizer and start time, so two of them form
  # a duplicate under whichever predicate admits both.
  defp insert_meeting!(organizer_id, status) do
    Repo.query!(
      """
      INSERT INTO meetings (id, uid, calendar_uid, title, start_time, end_time, organizer_name,
        organizer_email, attendee_name, attendee_email, organizer_user_id, status,
        inserted_at, updated_at)
      VALUES (gen_random_uuid(), gen_random_uuid()::text, gen_random_uuid()::text,
        'Verification index test', $1, $2,
        'Organizer', $3, 'Attendee', 'attendee@example.com', $4, $5, NOW(), NOW())
      """,
      [@slot, NaiveDateTime.add(@slot, 30, :minute), @organizer_email, organizer_id, status]
    )
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

  defp mark_invalid!(index) do
    Repo.query!("UPDATE pg_index SET indisvalid = false WHERE indexrelid = to_regclass($1)", [
      index
    ])
  end

  defp valid?(index) do
    %{rows: [[valid]]} =
      Repo.query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [index])

    valid
  end

  defp check_out! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
    end
  end
end
