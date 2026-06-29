defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditorTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        recurrence_rule: nil,
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        change_event: "update_create_recurrence"
      },
      overrides
    )
  end

  test "renders the frequency selector with all preset options" do
    html = render_component(&RecurrenceEditor.recurrence_editor/1, base_assigns())

    assert html =~ "Repeat"
    assert html =~ "Does not repeat"
    assert html =~ "Daily"
    assert html =~ "Weekly"
    assert html =~ "Monthly"
    assert html =~ "Yearly"
    assert html =~ ~s(phx-change="update_create_recurrence")
  end

  test "hides the detail controls when there is no rule" do
    html = render_component(&RecurrenceEditor.recurrence_editor/1, base_assigns())

    refute html =~ ~s(name="interval")
    refute html =~ ~s(name="end_type")
  end

  test "reveals weekday toggles and end conditions for a weekly rule" do
    assigns = base_assigns(%{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE"})
    html = render_component(&RecurrenceEditor.recurrence_editor/1, assigns)

    assert html =~ ~s(name="by_day[]")
    assert html =~ "Mon"
    assert html =~ "Wed"
    assert html =~ ~s(name="interval")
    assert html =~ ~s(name="end_type")
    # The selected weekdays render checked.
    assert html =~ ~r/value="mo"[^>]*checked/
    assert html =~ ~r/value="we"[^>]*checked/
  end

  test "shows a human-readable summary of the current rule" do
    assigns = base_assigns(%{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE"})
    html = render_component(&RecurrenceEditor.recurrence_editor/1, assigns)

    assert html =~ "Repeats weekly on Mon, Wed"
  end

  describe "summary/1" do
    test "summarises a simple weekly rule" do
      parsed = %{freq: :weekly, by_day: [:mo, :we]}
      assert RecurrenceEditor.summary(parsed) == "Repeats weekly on Mon, Wed"
    end

    test "summarises an interval and count" do
      parsed = %{freq: :daily, interval: 2, count: 5}
      assert RecurrenceEditor.summary(parsed) == "Repeats every 2 days for 5 occurrences"
    end

    test "summarises an until date" do
      parsed = %{freq: :weekly, until: ~D[2026-12-31]}
      assert RecurrenceEditor.summary(parsed) == "Repeats weekly until 2026-12-31"
    end

    test "returns nil for a non-recurring rule" do
      assert RecurrenceEditor.summary(%{}) == nil
    end
  end
end
