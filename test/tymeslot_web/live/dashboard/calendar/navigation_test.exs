defmodule TymeslotWeb.Dashboard.Calendar.NavigationTest do
  @moduledoc """
  The URL each calendar period lives at, the click that reaches it (draw at
  once in the browser, then patch the URL), and the translated copy the
  canvas hook is given.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias TymeslotWeb.Dashboard.Calendar.ClientStrings
  alias TymeslotWeb.Dashboard.Calendar.Navigation

  test "path/2 puts the view and date in the query" do
    assert Navigation.path(:three_day, ~D[2026-10-16]) ==
             "/dashboard/calendar?view=three_day&date=2026-10-16"
  end

  test "js/2 dispatches to the canvas first, then patches the URL" do
    assert [["dispatch", dispatch], ["patch", patch]] = Navigation.js(:week, ~D[2026-10-19]).ops

    assert dispatch.event == "calendar:navigate"
    assert dispatch.to == "#calendar-canvas"
    assert dispatch.detail == %{view: "week", date: "2026-10-19"}
    assert patch.href == "/dashboard/calendar?view=week&date=2026-10-19"
  end

  describe "ClientStrings.build/1" do
    test "weekdays run Monday to Sunday, whatever order the locale table keeps" do
      strings = ClientStrings.build("en")

      assert strings.weekdays == ~w(Mon Tue Wed Thu Fri Sat Sun)
      assert length(strings.months) == 12
    end

    test "carries every key the renderer reads" do
      keys =
        ~w(weekdays months all_day more also_here shown_as_free ended waiting_to_sync early_hours show_early_hours fold_early_hours open_day empty_day empty_three_day empty_week loading list_label)a

      assert keys -- Map.keys(ClientStrings.build("en")) == []
    end

    test "placeholders survive for the hook to fill" do
      strings = ClientStrings.build("en")

      assert strings.early_hours =~ "%{time}"
      assert strings.early_hours =~ "%{count}"
      assert strings.also_here =~ "%{titles}"
    end
  end
end
