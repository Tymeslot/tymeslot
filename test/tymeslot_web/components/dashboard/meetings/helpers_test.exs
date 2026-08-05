defmodule TymeslotWeb.Components.Dashboard.Meetings.HelpersTest do
  @moduledoc """
  Covers formatting in `format_meeting_date/2` and `format_meeting_time/3`.

  The date stays locale-ordered, while the clock is passed in: the dashboard is
  the organiser's own, so it follows the clock they chose rather than the one
  their language would imply.
  """

  use ExUnit.Case, async: true

  @moduletag :meetings
  @moduletag :components
  @moduletag :unit

  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  setup do
    on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)
    :ok
  end

  defp meeting(start_time, end_time) do
    %MeetingSchema{start_time: start_time, end_time: end_time}
  end

  describe "format_meeting_date/2" do
    test "formats in English word order for the en locale" do
      Gettext.put_locale(TymeslotWeb.Gettext, "en")
      m = meeting(~U[2026-01-05 14:30:00Z], ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_date(m, "Etc/UTC") == "January 05, 2026"
    end

    test "formats in German day-first order for the de locale" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      m = meeting(~U[2026-01-05 14:30:00Z], ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_date(m, "Etc/UTC") == "5. Januar 2026"
    end
  end

  describe "format_meeting_time/3" do
    test "formats the range on a 12-hour clock" do
      m = meeting(~U[2026-01-05 14:30:00Z], ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_time(m, "Etc/UTC", "12h") == "2:30 PM - 3:00 PM"
    end

    test "formats the range on a 24-hour clock" do
      m = meeting(~U[2026-01-05 14:30:00Z], ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_time(m, "Etc/UTC", "24h") == "14:30 - 15:00"
    end

    test "follows the chosen clock even when the language would imply the other" do
      # A German organiser who picked AM/PM keeps AM/PM; the date beside it
      # stays in German word order, because that is a separate concern.
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      m = meeting(~U[2026-01-05 14:30:00Z], ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_time(m, "Etc/UTC", "12h") == "2:30 PM - 3:00 PM"
      assert Helpers.format_meeting_date(m, "Etc/UTC") == "5. Januar 2026"
    end

    test "converts into the given timezone before formatting" do
      m = meeting(~U[2026-01-05 22:30:00Z], ~U[2026-01-05 23:00:00Z])

      assert Helpers.format_meeting_time(m, "Europe/Tallinn", "24h") == "00:30 - 01:00"
    end
  end
end
