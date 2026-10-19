defmodule Tymeslot.CalendarGrid.EventMoveDestinationTest do
  @moduledoc """
  Where a move to a CalDAV integration is filed when no calendar was chosen
  and its booking calendar resolves to nothing: the first collection it can
  write to, never a read-only share listed before it, and nowhere at all
  when every collection is read-only (which refuses the move before
  anything is written).
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.EventMove
  alias Tymeslot.Integrations.Calendar.CalendarEntry

  defp caldav(entries) do
    %{
      provider: "caldav",
      default_booking_calendar_id: "/dest/deleted/",
      calendar_paths: Enum.map(entries, & &1.path),
      calendar_list: entries
    }
  end

  defp entry(path, read_only),
    do: %CalendarEntry{id: path, path: path, name: path, selected: true, read_only: read_only}

  test "skips a read-only share listed first" do
    integration = caldav([entry("/dest/shared/", true), entry("/dest/work/", false)])

    assert EventMove.destination_calendar_id(integration, nil) == "/dest/work/"
  end

  test "resolves nothing when every collection is read-only" do
    integration = caldav([entry("/dest/shared/", true), entry("/dest/rota/", true)])

    assert EventMove.destination_calendar_id(integration, nil) == nil
  end

  test "keeps the calendar the organiser chose" do
    integration = caldav([entry("/dest/shared/", true), entry("/dest/work/", false)])

    assert EventMove.destination_calendar_id(integration, "/dest/work/") == "/dest/work/"
  end
end
