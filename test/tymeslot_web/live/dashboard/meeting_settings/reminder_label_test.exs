defmodule TymeslotWeb.Dashboard.MeetingSettings.ReminderLabelTest do
  @moduledoc """
  Covers the reminder lead times a meeting type shows: the number and its unit
  word, in the language the rest of the page is in.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :meeting_types

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.MeetingSettings.Components.Reminders

  defp in_locale(locale, fun), do: Gettext.with_locale(TymeslotWeb.Gettext, locale, fun)

  describe "reminder_label/2" do
    test "says the lead time in the reader's own language" do
      assert in_locale("de", fn -> Reminders.reminder_label(30, "minutes") end) == "30 Minuten"
      assert in_locale("de", fn -> Reminders.reminder_label(1, "hours") end) == "1 Stunde"
      assert in_locale("fr", fn -> Reminders.reminder_label(2, "days") end) == "2 jours"
    end

    test "picks the plural form the number calls for" do
      # Czech inflects after a number in three bands, which a lookup table of
      # singular/plural words cannot say.
      assert in_locale("cs", fn -> Reminders.reminder_label(1, "minutes") end) == "1 minutu"
      assert in_locale("cs", fn -> Reminders.reminder_label(2, "minutes") end) == "2 minuty"
      assert in_locale("cs", fn -> Reminders.reminder_label(30, "minutes") end) == "30 minut"
    end

    test "an unreadable unit still reads as a lead time" do
      assert in_locale("de", fn -> Reminders.reminder_label(30, "weeks") end) == "30 Minuten"
    end
  end

  describe "the configured reminders" do
    test "are shown whole, not half translated" do
      # The bug this covers: the sentence came from the catalogue while the
      # lead time inside it stayed English, so a German organiser was shown
      # "30 minutes vorher".
      html =
        in_locale("de", fn ->
          render_component(&Reminders.reminders_section/1, %{
            reminders: [%{value: 30, unit: "minutes"}],
            max_reminders: 3,
            new_reminder_value: "",
            new_reminder_unit: "minutes",
            reminder_error: nil,
            show_custom_reminder: false,
            reminder_confirmation: nil,
            form_errors: %{},
            myself: nil
          })
        end)

      assert html =~ "30 Minuten vorher"
      refute html =~ "30 minutes"
    end
  end
end
