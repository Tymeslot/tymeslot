defmodule TymeslotWeb.Components.Calendar.RemindersEditorTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Components.Calendar.RemindersEditor

  # The side panel offers `reminder_minutes_presets/0`, labelled by
  # `minutes_label/1`, and `parse_reminder/1` validates against the same list.
  test "every preset lead time is accepted by parse_reminder/1 and carries a label" do
    presets = ReminderForm.reminder_minutes_presets()
    refute Enum.empty?(presets)

    for minutes <- presets do
      assert ReminderForm.parse_reminder(%{"method" => "popup", "minutes" => to_string(minutes)}) ==
               {:ok, %{method: :popup, minutes_before: minutes}}

      assert String.trim(RemindersEditor.minutes_label(minutes)) != ""
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
