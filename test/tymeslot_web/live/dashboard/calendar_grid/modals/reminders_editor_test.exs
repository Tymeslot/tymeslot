defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditorTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RemindersEditor

  # The lead-time select's options, as `{minutes, label}`. The method select's
  # options carry non-numeric values, so they never match.
  defp offered_lead_times(html) do
    ~r/<option value="(\d+)"[^>]*>([^<]*)<\/option>/
    |> Regex.scan(html)
    |> Enum.map(fn [_match, minutes, label] -> {String.to_integer(minutes), label} end)
  end

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

  describe "the offered lead times against the whitelist that validates them" do
    # The editor's options and `parse_reminder/1`'s whitelist were once two
    # independent literals: an option added to one and not the other either
    # offered a lead time the server rejects, or accepted one never shown.

    test "every lead time the editor offers is accepted by parse_reminder/1" do
      html = render_component(&RemindersEditor.reminders_editor/1, base_assigns())
      offered = offered_lead_times(html)

      # Anchor: no options at all would make the rejection below vacuous.
      refute Enum.empty?(offered)

      assert Enum.map(offered, fn {minutes, _label} -> minutes end) ==
               Shared.reminder_minutes_presets()

      assert Enum.reject(offered, fn {minutes, _label} ->
               Shared.parse_reminder(%{"method" => "popup", "minutes" => to_string(minutes)}) ==
                 {:ok, %{method: :popup, minutes_before: minutes}}
             end) == []
    end

    test "every offered lead time carries a label" do
      html = render_component(&RemindersEditor.reminders_editor/1, base_assigns())
      offered = offered_lead_times(html)

      refute Enum.empty?(offered)
      assert Enum.reject(offered, fn {_minutes, label} -> String.trim(label) != "" end) == []
    end
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
