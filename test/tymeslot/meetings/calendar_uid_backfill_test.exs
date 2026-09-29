defmodule Tymeslot.Meetings.CalendarUidBackfillTest do
  @moduledoc """
  Drives `20260928144321_add_calendar_uid_to_meetings` itself.

  Every meeting that exists when the migration runs already has an event in
  its organiser's calendar, keyed by the meeting's `uid`. The migration copies
  that value into `calendar_uid`, so the event keeps matching; the tests below
  pin that copy and the two constraints that follow it.

  The migration module is loaded from `priv` and run through
  `Ecto.Migrator`; see `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :meetings

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_928_144_321

  test "gives every existing meeting its uid as its calendar uid" do
    meetings = for status <- ~w(confirmed cancelled pending), do: insert(:meeting, status: status)

    # The factory's calendar uid is independent of the uid, so a row whose
    # calendar uid equals its uid afterwards was written by the migration.
    assert Enum.all?(meetings, &(&1.calendar_uid != &1.uid))

    MigrationRunner.rerun!(@version)

    assert Enum.map(meetings, &Repo.reload!(&1).calendar_uid) == Enum.map(meetings, & &1.uid)
  end

  test "leaves no meeting without a calendar uid" do
    meeting = insert(:meeting)
    MigrationRunner.rerun!(@version)

    assert_raise Postgrex.Error, ~r/not_null_violation|null value in column "calendar_uid"/, fn ->
      Repo.query!("UPDATE meetings SET calendar_uid = NULL WHERE id = $1", [
        UUID.dump!(meeting.id)
      ])
    end
  end

  test "keeps calendar uids unique" do
    first = insert(:meeting)
    second = insert(:meeting)
    MigrationRunner.rerun!(@version)

    assert_raise Postgrex.Error, ~r/unique_violation|meetings_calendar_uid_index/, fn ->
      Repo.query!("UPDATE meetings SET calendar_uid = $1 WHERE id = $2", [
        first.uid,
        UUID.dump!(second.id)
      ])
    end
  end
end
