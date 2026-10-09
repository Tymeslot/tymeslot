defmodule Tymeslot.Repo.Migrations.RelaxMeetingsAttendeeColumnsNullableTest do
  @moduledoc """
  The repair migration makes the attendee columns nullable on a database
  that ran the original `create_meetings` with `NOT NULL`, and must change
  nothing on one that already has them nullable (a fresh install, which runs
  the patched original).
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :migrations

  alias Tymeslot.Test.MigrationRunner

  @version 20_261_002_161_423
  @columns ["attendee_email", "attendee_name"]

  defp nullability do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT column_name, is_nullable FROM information_schema.columns
        WHERE table_name = 'meetings' AND column_name = ANY($1)
        ORDER BY column_name
        """,
        [@columns]
      )

    rows
  end

  test "makes NOT NULL attendee columns nullable" do
    for column <- @columns do
      Repo.query!("ALTER TABLE meetings ALTER COLUMN #{column} SET NOT NULL")
    end

    assert nullability() == [["attendee_email", "NO"], ["attendee_name", "NO"]]

    MigrationRunner.replay!(@version)

    assert nullability() == [["attendee_email", "YES"], ["attendee_name", "YES"]]
  end

  test "leaves already nullable attendee columns nullable" do
    assert nullability() == [["attendee_email", "YES"], ["attendee_name", "YES"]]

    MigrationRunner.replay!(@version)

    assert nullability() == [["attendee_email", "YES"], ["attendee_name", "YES"]]
  end
end
