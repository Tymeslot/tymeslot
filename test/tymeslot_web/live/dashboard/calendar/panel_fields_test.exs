defmodule TymeslotWeb.Dashboard.Calendar.PanelFieldsTest do
  @moduledoc """
  The reminder list an open event's add and remove write, held to what the
  event's calendar keeps (`CreateParams.reminder_capacity/1`).
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Reminder
  alias TymeslotWeb.Dashboard.Calendar.PanelFields

  defp alarms(reminders),
    do: Enum.map(reminders, &{Reminder.method(&1), Reminder.minutes_before(&1)})

  describe "add_reminder/3" do
    test "an Outlook calendar, which keeps one notification, takes no second reminder" do
      assert PanelFields.add_reminder(
               [%{method: :popup, minutes_before: 30}],
               %{"minutes" => "10", "method" => "popup"},
               "outlook"
             ) == :error
    end

    test "an Outlook calendar writes a notification whatever method the row sent" do
      assert {:ok, reminders} =
               PanelFields.add_reminder([], %{"minutes" => "10", "method" => "email"}, "outlook")

      assert alarms(reminders) == [{:popup, 10}]
    end

    test "a calendar holding its most reminders takes no more" do
      full = for minutes <- [5, 10, 30, 60, 1440], do: %{method: :popup, minutes_before: minutes}

      assert PanelFields.add_reminder(full, %{"minutes" => "5", "method" => "email"}, "google") ==
               :error
    end

    test "a cached string-keyed alarm counts as the reminder it is" do
      cached = [%{"method" => "email", "minutes_before" => 60}]

      assert PanelFields.add_reminder(cached, %{"minutes" => "60", "method" => "email"}, "google") ==
               :error
    end
  end

  describe "drop_reminder/3" do
    test "a negative index removes nothing" do
      reminders = [%{method: :popup, minutes_before: 30}]
      assert PanelFields.drop_reminder(reminders, "-1", "popup:30") == :error
    end
  end
end
