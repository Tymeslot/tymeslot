defmodule TymeslotWeb.Components.Dashboard.Meetings.HelpersTest do
  @moduledoc """
  Covers locale-aware formatting in `format_meeting_date/2` and
  `format_meeting_time/2` — both must route through `LocaleFormat` rather
  than hand-rolling English word order or 12-hour time.
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

  describe "format_meeting_time/2" do
    test "formats as 12-hour AM/PM for the en locale" do
      Gettext.put_locale(TymeslotWeb.Gettext, "en")
      m = meeting(~U[2026-01-05 14:30:00Z], ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_time(m, "Etc/UTC") == "02:30 PM - 03:00 PM"
    end

    test "formats as 24-hour time for the de locale" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      m = meeting(~U[2026-01-05 14:30:00Z], ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_time(m, "Etc/UTC") == "14:30 - 15:00"
    end
  end
end
