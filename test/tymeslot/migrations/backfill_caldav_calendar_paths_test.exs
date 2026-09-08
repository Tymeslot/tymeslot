defmodule Tymeslot.Migrations.BackfillCaldavCalendarPathsTest do
  @moduledoc """
  Value-correctness regression for
  `20260907194756_backfill_caldav_calendar_paths_from_booking_calendar`, which
  re-selects the booking calendar on CalDAV integrations whose `calendar_paths`
  was emptied by a reconnect or re-discovery that matched nothing.

  The migration is driven from `priv` (`MigrationRunner.replay!/2`, since its
  `down/0` is a no-op) so the assertions are about the SQL that ships. Which
  rows it touches is the whole point: a CalDAV sync iterates `calendar_paths`
  and nothing else, so a row left unrepaired syncs no calendars, while a row
  repaired on a guess would start writing bookings into a calendar the owner
  never chose.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar
  @moduletag :integrations
  @moduletag :migrations

  alias Tymeslot.Repo

  alias Tymeslot.Test.MigrationRunner

  @version 20_260_907_194_756

  @booking_path "/calendars/alice/bookings/"
  @holidays_path "/calendars/alice/holidays/"

  describe "up/0" do
    test "re-selects the booking calendar and restores calendar_paths" do
      id = insert_integration(calendar_list: [entry(@booking_path), entry(@holidays_path)])

      MigrationRunner.replay!(@version)

      assert calendar_paths(id) == [@booking_path]
      assert selected_paths(id) == [@booking_path]
    end

    test "leaves an integration whose calendar_list is empty" do
      id = insert_integration(calendar_list: [])

      MigrationRunner.replay!(@version)

      # Nothing to derive from; the sync now surfaces this for reconnection.
      assert calendar_paths(id) == []
    end

    test "leaves an integration whose booking calendar is no longer listed" do
      id = insert_integration(calendar_list: [entry(@holidays_path)])

      MigrationRunner.replay!(@version)

      assert calendar_paths(id) == []
    end

    test "leaves an integration with no booking calendar set" do
      id =
        insert_integration(
          calendar_list: [entry(@booking_path)],
          default_booking_calendar_id: nil
        )

      MigrationRunner.replay!(@version)

      assert calendar_paths(id) == []
    end

    test "never selects a read-only calendar" do
      id =
        insert_integration(
          calendar_list: [entry(@booking_path, read_only: true)],
          default_booking_calendar_id: @booking_path
        )

      MigrationRunner.replay!(@version)

      # Bookings cannot be written to a read-only calendar, so repairing to it
      # would trade a silent no-op for a sync that fails on every write.
      assert calendar_paths(id) == []
    end

    test "leaves an integration that already has a selection untouched" do
      id =
        insert_integration(
          calendar_list: [entry(@holidays_path, selected: true)],
          calendar_paths: [@holidays_path]
        )

      MigrationRunner.replay!(@version)

      assert calendar_paths(id) == [@holidays_path]
    end

    test "repairs every provider in the CalDAV family, not only \"caldav\"" do
      # Nextcloud, Radicale and the rest are stored under their own provider
      # string but sync by path exactly as "caldav" does, and the companion
      # change flags all of them for reconnection when calendar_paths is empty.
      id = insert_integration(provider: "nextcloud", calendar_list: [entry(@booking_path)])

      MigrationRunner.replay!(@version)

      assert calendar_paths(id) == [@booking_path]
      assert selected_paths(id) == [@booking_path]
    end

    test "leaves a non-CalDAV integration alone" do
      # Google and Outlook sync by token, not by path, so an empty
      # calendar_paths is their normal state and must not be written to.
      id = insert_integration(provider: "google", calendar_list: [entry(@booking_path)])

      MigrationRunner.replay!(@version)

      assert calendar_paths(id) == []
    end
  end

  defp insert_integration(overrides) do
    user = insert(:user)

    attrs =
      Keyword.merge(
        [
          provider: "caldav",
          calendar_paths: [],
          default_booking_calendar_id: @booking_path,
          is_active: true
        ],
        overrides
      )

    insert(:calendar_integration, [user: user] ++ attrs).id
  end

  defp entry(path, opts \\ []) do
    %{
      "id" => path,
      "path" => path,
      "name" => path,
      "type" => "calendar",
      "selected" => Keyword.get(opts, :selected, false),
      "read_only" => Keyword.get(opts, :read_only, false)
    }
  end

  defp calendar_paths(id) do
    Repo.one!(from(c in "calendar_integrations", where: c.id == ^id, select: c.calendar_paths)) ||
      []
  end

  defp selected_paths(id) do
    "calendar_integrations"
    |> from(where: [id: ^id], select: [:calendar_list])
    |> Repo.one!()
    |> Map.fetch!(:calendar_list)
    |> Enum.filter(&(&1["selected"] == true))
    |> Enum.map(& &1["path"])
  end
end
