defmodule Tymeslot.Migrations.BackfillFirstAnnouncedAtTest do
  @moduledoc """
  Value-correctness regression for
  `20260904094815_backfill_first_announced_at_for_pre_announcement_bookings`,
  which stamps `first_announced_at` on bookings that were live before
  `announced_at` existed to record it.

  The migration is driven from `priv` (`MigrationRunner.replay!/2`, since its
  `down/0` is a no-op) so the assertions are about the SQL that ships. What
  matters is which rows it touches: a booking left unstamped is one
  `Meetings.Approval.refund_unapproved_request/1` will auto-refund in full
  after a decline, and a booking stamped wrongly is one it will refuse to
  refund at all.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :meetings
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_904_094_815

  @inserted_at ~U[2026-05-01 09:00:00Z]
  @announced_at ~U[2026-08-30 12:00:00Z]

  describe "up/0" do
    test "stamps a confirmed booking that predates announced_at with its inserted_at" do
      meeting = pre_announcement_meeting("confirmed")

      MigrationRunner.replay!(@version)

      assert first_announced_at(meeting) == @inserted_at
    end

    test "stamps a completed booking too" do
      meeting = pre_announcement_meeting("completed")

      MigrationRunner.replay!(@version)

      assert first_announced_at(meeting) == @inserted_at
    end

    test "leaves bookings that were never live unstamped" do
      never_live =
        for status <- ["awaiting_approval", "pending", "awaiting_payment", "expired"],
            do: {status, pre_announcement_meeting(status)}

      MigrationRunner.replay!(@version)

      assert Enum.reject(never_live, fn {_status, meeting} ->
               is_nil(first_announced_at(meeting))
             end) == []
    end

    test "leaves a cancelled booking unstamped: it can never re-enter the gate" do
      meeting = pre_announcement_meeting("cancelled")

      MigrationRunner.replay!(@version)

      assert is_nil(first_announced_at(meeting))
    end

    test "keeps an existing first_announced_at rather than overwriting it" do
      meeting = pre_announcement_meeting("confirmed")
      stamp!(meeting, announced_at: @announced_at, first_announced_at: @announced_at)

      MigrationRunner.replay!(@version)

      assert first_announced_at(meeting) == @announced_at
    end

    test "prefers announced_at over inserted_at when the row has one" do
      meeting = pre_announcement_meeting("confirmed")
      stamp!(meeting, announced_at: @announced_at)

      MigrationRunner.replay!(@version)

      assert first_announced_at(meeting) == @announced_at
    end
  end

  # The pre-migration row: created long before `announced_at` shipped, so it
  # carries neither timestamp.
  defp pre_announcement_meeting(status) do
    meeting = insert(:meeting, status: status, inserted_at: @inserted_at)
    stamp!(meeting, announced_at: nil, first_announced_at: nil)
    meeting
  end

  # Written past the schema deliberately: these columns are not meant to be
  # settable to arbitrary history through a changeset.
  defp stamp!(meeting, fields) do
    {columns, values} = Enum.unzip(fields)

    assignments =
      columns
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {column, index} -> "#{column} = $#{index}" end)

    Repo.query!(
      "UPDATE meetings SET #{assignments} WHERE id = $#{length(columns) + 1}",
      values ++ [UUID.dump!(meeting.id)]
    )
  end

  defp first_announced_at(meeting) do
    %{rows: [[value]]} =
      Repo.query!("SELECT first_announced_at FROM meetings WHERE id = $1", [
        UUID.dump!(meeting.id)
      ])

    to_utc(value)
  end

  # The column is `timestamp without time zone` holding UTC, so raw SQL reads
  # it back naive; the assertions are about instants.
  defp to_utc(nil), do: nil
  defp to_utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_utc(%DateTime{} = value), do: value
end
