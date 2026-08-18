defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditorTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditor

  defp base_assigns(overrides \\ %{}) do
    Map.merge(
      %{
        reminders: [],
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        add_event: "add_event_reminder",
        remove_event: "remove_event_reminder"
      },
      overrides
    )
  end

  test "renders the add-reminder control with presets and methods" do
    html = render_component(&RemindersEditor.reminders_editor/1, base_assigns())

    assert html =~ "Reminders"
    assert html =~ "Add reminder"
    assert html =~ "10 minutes before"
    assert html =~ "1 day before"
    assert html =~ "Notification"
    assert html =~ "Email"
    assert html =~ ~s(phx-submit="add_event_reminder")
  end

  test "renders existing reminders as removable rows with their lead time" do
    assigns =
      base_assigns(%{
        reminders: [
          %{method: :popup, minutes_before: 10},
          %{method: :email, minutes_before: 1440}
        ]
      })

    html = render_component(&RemindersEditor.reminders_editor/1, assigns)

    assert html =~ "Notification 10 minutes before"
    assert html =~ "Email 1 day before"
    assert html =~ ~s(phx-click="remove_event_reminder")
    assert html =~ ~s(phx-value-index="0")
    assert html =~ ~s(phx-value-index="1")
  end

  describe "reminder_label/1" do
    test "labels popup minutes" do
      assert RemindersEditor.reminder_label(%{method: :popup, minutes_before: 30}) ==
               "Notification 30 minutes before"
    end

    test "labels email hours" do
      assert RemindersEditor.reminder_label(%{method: :email, minutes_before: 60}) ==
               "Email 1 hour before"
    end

    test "labels a full day" do
      assert RemindersEditor.reminder_label(%{method: :popup, minutes_before: 1440}) ==
               "Notification 1 day before"
    end

    test "labels a string-keyed reminder straight out of the cache column" do
      assert RemindersEditor.reminder_label(%{"method" => "popup", "minutes_before" => 30}) ==
               "Notification 30 minutes before"

      assert RemindersEditor.reminder_label(%{"method" => "email", "minutes_before" => 60}) ==
               "Email 1 hour before"
    end

    test "labels a reminder with no parsable lead time" do
      assert RemindersEditor.reminder_label(%{method: :popup, minutes_before: nil}) ==
               "Notification before the event"
    end
  end
end
