defmodule TymeslotWeb.Dashboard.Calendar.NavigationTest do
  @moduledoc """
  The URL each calendar period lives at, the click that reaches it (draw at
  once in the browser, then patch the URL), and the translated copy the
  canvas hook is given.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias ExUnit.CaptureLog
  alias TymeslotWeb.Dashboard.Calendar.ClientStrings
  alias TymeslotWeb.Dashboard.Calendar.Navigation

  test "path/2 puts the view and date in the query" do
    assert Navigation.path(:three_day, ~D[2026-10-16]) ==
             "/dashboard/calendar?view=three_day&date=2026-10-16"
  end

  test "js/3 patches the URL first, then dispatches to the canvas" do
    assert [["patch", patch], ["dispatch", dispatch]] = Navigation.js(:week, ~D[2026-10-19]).ops

    assert dispatch.event == "calendar:navigate"
    assert dispatch.to == "#calendar-canvas"
    assert dispatch.detail == %{view: "week", date: "2026-10-19"}
    assert patch.href == "/dashboard/calendar?view=week&date=2026-10-19"
  end

  test "js/3 tells the canvas the step of a previous or next control" do
    assert [_patch, ["dispatch", dispatch]] = Navigation.js(:day, ~D[2026-10-19], step: -1).ops

    assert dispatch.detail == %{view: "day", date: "2026-10-19", step: -1}
  end

  test "js/3 does not patch to the period already shown, but still tells the canvas" do
    assert [["dispatch", dispatch]] =
             Navigation.js(:week, ~D[2026-10-14], from: {:week, ~D[2026-10-14]}).ops

    assert dispatch.detail == %{view: "week", date: "2026-10-14"}
  end

  test "js/3 patches when the shown period differs in view or date" do
    assert [["patch", _patch], _dispatch] =
             Navigation.js(:day, ~D[2026-10-14], from: {:week, ~D[2026-10-14]}).ops

    assert [["patch", _patch], _dispatch] =
             Navigation.js(:week, ~D[2026-10-15], from: {:week, ~D[2026-10-14]}).ops
  end

  describe "ClientStrings.build/1" do
    test "carries every key quick create reads" do
      keys =
        ~w(new_event quick_create_label quick_create_placeholder quick_create_hint save save_and_invite more_options show_as busy free date_chip start_chip end_chip time_to all_day_chip calendar_chip place_chip guests_chip saving_draft create_refused)a

      assert keys -- Map.keys(ClientStrings.build("en")) == []
    end

    test "quick create's words" do
      strings = ClientStrings.build("en")

      assert strings.save_and_invite == "Save and invite"
      assert strings.saving_draft == "Saving…"
      assert strings.quick_create_hint =~ "@email"
    end

    test "weekdays run Monday to Sunday, whatever order the locale table keeps" do
      strings = ClientStrings.build("en")

      assert strings.weekdays == ~w(Mon Tue Wed Thu Fri Sat Sun)
      assert length(strings.months) == 12
    end

    test "the first of the month is the ordinal the language writes it as" do
      assert ClientStrings.build("fr").first_of_month == "1er"
      assert ClientStrings.build("it").first_of_month == "1°"
      assert ClientStrings.build("en").first_of_month == "1"
    end

    test "carries every key the renderer reads" do
      keys =
        ~w(weekdays months first_of_month all_day more allday_more also_here shown_as_free ended waiting_to_sync early_hours show_early_hours fold_early_hours open_day empty_day empty_three_day empty_week loading list_label)a

      assert keys -- Map.keys(ClientStrings.build("en")) == []
    end

    test "carries the words a booking request is drawn with" do
      strings = ClientStrings.build("en")

      assert strings.request == "Request"
      assert strings.request_expired == "Expired"
      assert strings.request_aria == "request waiting for your answer"
      assert strings.request_expired_aria == "request expired without an answer"
      assert strings.request_waiting == "a request waiting for your answer"
    end

    test "the move mode's strings keep their placeholders for the hook" do
      strings = ClientStrings.build("en")

      assert strings.range_on_day == "%{date}, %{start} to %{finish}"
      assert strings.moving =~ "%{title}"
      assert strings.moving =~ "%{when}"
      assert strings.move_cancelled =~ "%{when}"
      assert strings.move_saving =~ "%{title}"
    end

    test "placeholders survive for the hook to fill" do
      strings = ClientStrings.build("en")

      assert strings.early_hours =~ "%{time}"
      assert strings.early_hours =~ "%{count}"
      assert strings.also_here =~ "%{titles}"
      assert strings.allday_more =~ "%{count}"
      assert strings.allday_more =~ "%{date}"

      refute CaptureLog.capture_log(fn -> ClientStrings.build("en") end) =~
               "missing Gettext bindings"
    end
  end
end
