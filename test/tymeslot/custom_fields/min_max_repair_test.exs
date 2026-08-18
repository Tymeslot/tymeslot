defmodule Tymeslot.CustomFields.MinMaxRepairTest do
  @moduledoc """
  Drives migration 20260615093519_repair_custom_field_min_max_strings, which
  stringifies custom-field `min`/`max` bounds that were persisted as JSON
  numbers under the earlier `:integer` schema.

  A numeric bound makes `Ecto.Embedded.load/3` raise
  `cannot load 1 as type :string` and crashes any query touching the row, so
  the decisive assertion is that the row loads through the schema afterwards.

  The migration repairs two columns — `meeting_types.custom_fields` and
  `meetings.custom_fields_snapshot` — and both are covered here, because the
  migration module itself is loaded from `priv` and run through
  `Ecto.Migrator`; see `Tymeslot.Test.MigrationRunner`.

  Runs non-async because it writes raw rows that bypass changesets to
  reproduce the pre-migration data shape.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :custom_fields
  @moduletag :database

  alias Ecto.UUID
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_615_093_519

  describe "min/max repair on meeting_types.custom_fields" do
    test "stringifies numeric bounds and the row loads through the schema" do
      user = insert(:user)

      id =
        insert_raw_meeting_type(user.id, [
          %{
            "id" => "a",
            "type" => "number",
            "label" => "Count",
            "position" => 0,
            "min" => 1,
            "max" => 20
          }
        ])

      run_repair!()

      mt = Repo.get!(MeetingTypeSchema, id)
      [field] = mt.custom_fields

      assert field.min == "1"
      assert field.max == "20"
    end

    test "preserves array order and other fields" do
      user = insert(:user)

      id =
        insert_raw_meeting_type(user.id, [
          %{"id" => "a", "type" => "note", "label" => "Intro", "position" => 0, "body" => "hi"},
          %{
            "id" => "b",
            "type" => "number",
            "label" => "Count",
            "position" => 1,
            "min" => 5,
            "max" => 50
          },
          %{"id" => "c", "type" => "short_text", "label" => "Name", "position" => 2}
        ])

      run_repair!()

      mt = Repo.get!(MeetingTypeSchema, id)

      assert Enum.map(mt.custom_fields, & &1.id) == ["a", "b", "c"]
      number = Enum.find(mt.custom_fields, &(&1.type == "number"))
      assert {number.min, number.max} == {"5", "50"}
      assert Enum.find(mt.custom_fields, &(&1.type == "note")).body == "hi"
    end

    test "leaves already-string bounds untouched and is a no-op when re-run" do
      user = insert(:user)

      id =
        insert_raw_meeting_type(user.id, [
          %{
            "id" => "a",
            "type" => "number",
            "label" => "Count",
            "position" => 0,
            "min" => "3",
            "max" => "9"
          }
        ])

      run_repair!()
      # Idempotent: a second pass must not corrupt already-string values.
      run_repair!()

      mt = Repo.get!(MeetingTypeSchema, id)
      [field] = mt.custom_fields
      assert {field.min, field.max} == {"3", "9"}
    end

    test "handles only one bound being numeric" do
      user = insert(:user)

      id =
        insert_raw_meeting_type(user.id, [
          %{"id" => "a", "type" => "number", "label" => "Count", "position" => 0, "min" => 1}
        ])

      run_repair!()

      mt = Repo.get!(MeetingTypeSchema, id)
      [field] = mt.custom_fields
      assert field.min == "1"
      assert field.max == nil
    end
  end

  describe "min/max repair on meetings.custom_fields_snapshot" do
    test "stringifies numeric bounds in the snapshot copied onto a booking" do
      meeting = insert(:meeting)

      write_raw_snapshot(meeting.id, [
        %{
          "id" => "a",
          "type" => "number",
          "label" => "Count",
          "position" => 0,
          "min" => 1,
          "max" => 20
        },
        %{"id" => "b", "type" => "short_text", "label" => "Name", "position" => 1}
      ])

      run_repair!()

      assert [number, text] = raw_snapshot(meeting.id)
      assert number["min"] == "1"
      assert number["max"] == "20"
      assert number["label"] == "Count"
      assert text["id"] == "b"
    end

    test "leaves an already-string snapshot untouched" do
      meeting = insert(:meeting)

      write_raw_snapshot(meeting.id, [
        %{
          "id" => "a",
          "type" => "number",
          "label" => "Count",
          "position" => 0,
          "min" => "3",
          "max" => "9"
        }
      ])

      run_repair!()

      assert [field] = raw_snapshot(meeting.id)
      assert {field["min"], field["max"]} == {"3", "9"}
    end
  end

  # -- Helpers ----------------------------------------------------------------

  # `down/0` is a deliberate no-op and `up/0` only rewrites rows that still
  # hold a numeric bound, so the version is dropped from the ledger and the
  # migration re-applied. One call repairs both columns, as it does in
  # production.
  defp run_repair! do
    MigrationRunner.replay!(@version)
  end

  # Inserts a meeting_type bypassing changesets, with custom_fields built
  # directly as a jsonb[] so numeric bounds survive into the database.
  # Each element is a plain map that Postgrex encodes as a jsonb object,
  # preserving integer min/max as JSON numbers.
  defp insert_raw_meeting_type(user_id, elements) do
    now = DateTime.utc_now(:second)
    placeholders = Enum.map_join(1..length(elements), ",", &"$#{&1 + 4}::jsonb")

    params = [user_id, "Test type", 30, now] ++ elements

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO meeting_types
          (user_id, name, duration_minutes, inserted_at, updated_at, custom_fields)
        VALUES ($1, $2, $3, $4::timestamp, $4::timestamp, ARRAY[#{placeholders}]::jsonb[])
        RETURNING id
        """,
        params
      )

    id
  end

  # The snapshot is written past the schema, which would cast the bounds to
  # strings on the way in — the point is to reproduce the JSON numbers the old
  # `:integer` schema left behind.
  defp write_raw_snapshot(meeting_id, elements) do
    placeholders = Enum.map_join(1..length(elements), ",", &"$#{&1 + 1}::jsonb")

    Repo.query!(
      """
      UPDATE meetings
      SET custom_fields_snapshot = ARRAY[#{placeholders}]::jsonb[]
      WHERE id = $1
      """,
      [UUID.dump!(meeting_id) | elements]
    )
  end

  defp raw_snapshot(meeting_id) do
    %{rows: [[snapshot]]} =
      Repo.query!("SELECT custom_fields_snapshot FROM meetings WHERE id = $1", [
        UUID.dump!(meeting_id)
      ])

    snapshot
  end
end
