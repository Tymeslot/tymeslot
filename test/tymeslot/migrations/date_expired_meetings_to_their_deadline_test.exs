defmodule Tymeslot.Migrations.DateExpiredMeetingsToTheirDeadlineTest do
  @moduledoc """
  Value-correctness regression for
  `20261121065000_date_expired_meetings_to_their_deadline`, which dates each
  meeting that expired at a deadline (a reschedule request, an approval, an
  email verification) to that deadline rather than to whenever its expiry
  ran.

  Driven from `priv` (`MigrationRunner.replay!/1`, since its `down/0` is a
  no-op), so the assertions are about the SQL that ships. What matters is
  that every expiry lands on its deadline and nothing else moves.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :meetings
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_121_065_000

  # The 1.48.0 deploy, when the sweep expired every request already open.
  @swept_at ~U[2026-11-20 10:15:03Z]

  describe "up/0 for a lapsed reschedule request" do
    test "dates a request swept long after its meeting to the meeting's start" do
      meeting =
        meeting!(:expired,
          reschedule_requested_at: ~U[2026-07-14 09:00:00Z],
          start_time: ~U[2026-08-13 09:00:00Z],
          cancelled_at: @swept_at
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == ~U[2026-08-13 09:00:00Z]
    end

    test "dates a request made just before its meeting to the end of its window" do
      meeting =
        meeting!(:expired,
          reschedule_requested_at: ~U[2026-09-22 09:00:00Z],
          start_time: ~U[2026-09-23 09:00:00Z],
          cancelled_at: @swept_at
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == ~U[2026-09-29 09:00:00Z]
    end

    test "moves a request its own job expired on time by the job's delay only" do
      meeting =
        meeting!(:expired,
          reschedule_requested_at: ~U[2026-11-12 09:00:00.123456Z],
          start_time: ~U[2026-11-13 09:00:00Z],
          cancelled_at: ~U[2026-11-19 09:00:41Z]
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == ~U[2026-11-19 09:00:00Z]
    end

    test "leaves other meetings alone" do
      untouched = [
        # Expired with no deadline at all: a checkout nobody completed.
        meeting!(:expired, reschedule_requested_at: nil, cancelled_at: @swept_at),
        # Cancelled by the host while a request was open.
        meeting!(:cancelled,
          reschedule_requested_at: ~U[2026-10-12 09:00:00Z],
          cancelled_at: ~U[2026-10-14 09:00:00Z]
        ),
        # Still open.
        meeting!(:confirmed, reschedule_requested_at: ~U[2026-11-20 09:00:00Z], cancelled_at: nil)
      ]

      before = Enum.map(untouched, &cancelled_at/1)
      MigrationRunner.replay!(@version)

      assert Enum.map(untouched, &cancelled_at/1) == before
    end
  end

  describe "up/0 for a booking request nobody approved" do
    test "dates it as resolved and ended at its approval deadline" do
      meeting =
        meeting!(:expired,
          approval_deadline_at: ~U[2026-08-20 12:00:00Z],
          approval_resolved_at: @swept_at,
          cancelled_at: @swept_at
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == ~U[2026-08-20 12:00:00Z]
      assert column(meeting, "approval_resolved_at") == ~U[2026-08-20 12:00:00Z]
    end

    # An approval keeps the deadline and stamps `approval_resolved_at`, so
    # only the missing `cancelled_at` tells this row from an approval expiry.
    test "leaves an approved booking whose checkout later expired undated" do
      meeting =
        meeting!(:expired,
          approval_deadline_at: ~U[2026-08-20 12:00:00Z],
          approval_resolved_at: ~U[2026-08-19 08:00:00Z],
          cancelled_at: nil
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == nil
      assert column(meeting, "approval_resolved_at") == ~U[2026-08-19 08:00:00Z]
    end

    test "leaves a declined request at the time the host declined" do
      meeting =
        meeting!(:cancelled,
          approval_deadline_at: ~U[2026-08-20 12:00:00Z],
          approval_resolved_at: ~U[2026-08-22 08:00:00Z],
          approval_declined_at: ~U[2026-08-22 08:00:00Z],
          cancelled_at: ~U[2026-08-22 08:00:00Z]
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == ~U[2026-08-22 08:00:00Z]
    end
  end

  describe "up/0 for a booking nobody verified" do
    test "dates it as ended at its verification deadline" do
      meeting =
        meeting!(:expired,
          verification_deadline_at: ~U[2026-11-14 10:00:00Z],
          cancelled_at: ~U[2026-11-16 03:05:00Z]
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == ~U[2026-11-14 10:00:00Z]
    end

    test "leaves a verified booking that expired later in the approval gate to that gate" do
      meeting =
        meeting!(:expired,
          verification_deadline_at: ~U[2026-11-14 10:00:00Z],
          email_verified_at: ~U[2026-11-13 18:00:00Z],
          approval_deadline_at: ~U[2026-11-17 18:00:00Z],
          approval_resolved_at: ~U[2026-11-17 18:00:20Z],
          cancelled_at: ~U[2026-11-17 18:00:20Z]
        )

      MigrationRunner.replay!(@version)

      assert cancelled_at(meeting) == ~U[2026-11-17 18:00:00Z]
    end
  end

  test "running up/0 a second time changes nothing" do
    meetings = [
      meeting!(:expired,
        reschedule_requested_at: ~U[2026-07-14 09:00:00Z],
        start_time: ~U[2026-08-13 09:00:00Z],
        cancelled_at: @swept_at
      ),
      meeting!(:expired,
        approval_deadline_at: ~U[2026-08-20 12:00:00Z],
        approval_resolved_at: @swept_at,
        cancelled_at: @swept_at
      ),
      meeting!(:expired,
        verification_deadline_at: ~U[2026-11-14 10:00:00Z],
        cancelled_at: ~U[2026-11-16 03:05:00Z]
      )
    ]

    before = dates(meetings)
    MigrationRunner.replay!(@version)
    once = dates(meetings)
    MigrationRunner.replay!(@version)

    assert once != before
    assert dates(meetings) == once
  end

  defp dates(meetings) do
    for meeting <- meetings,
        do: {cancelled_at(meeting), column(meeting, "approval_resolved_at")}
  end

  # Written past the schema deliberately: an expired meeting's dates are not
  # settable through a changeset.
  defp meeting!(status, fields) do
    meeting = insert(:meeting, status: status)
    {columns, values} = Enum.unzip(fields)

    assignments =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {column, index} -> "#{column} = $#{index}" end)

    Repo.query!(
      "UPDATE meetings SET #{assignments} WHERE id = $#{length(columns) + 1}",
      values ++ [UUID.dump!(meeting.id)]
    )

    meeting
  end

  defp cancelled_at(meeting), do: column(meeting, "cancelled_at")

  defp column(meeting, name) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{name} FROM meetings WHERE id = $1", [UUID.dump!(meeting.id)])

    to_utc(value)
  end

  # The column is `timestamp without time zone` holding UTC, so raw SQL reads
  # it back naive; the assertions are about instants.
  defp to_utc(nil), do: nil
  defp to_utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_utc(%DateTime{} = value), do: value
end
