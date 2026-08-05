defmodule TymeslotWeb.TimeFormatAudienceTest do
  @moduledoc """
  Guards the rule that keeps the clock preference honest: it formats the
  organiser who set it, and nobody else.

  These two surfaces are deliberately tested together, because the bug worth
  preventing is invisible when each is tested alone. If the organiser's setting
  ever leaks onto the booking page, a German attendee starts receiving AM/PM
  times inside an otherwise fully German page, purely because the organiser
  prefers them.
  """

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :utils
  @moduletag :unit

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  setup do
    on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)
    :ok
  end

  defp meeting(start_time, end_time) do
    %Tymeslot.Meetings.MeetingSchema{start_time: start_time, end_time: end_time}
  end

  describe "an organiser who prefers AM/PM while reading German" do
    setup do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      %{chosen: TimeFormat.resolve("12h", "de"), slot: ~U[2026-01-05 14:30:00Z]}
    end

    test "sees their own dashboard on the clock they chose", %{chosen: chosen, slot: slot} do
      m = meeting(slot, ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_time(m, "Etc/UTC", chosen) == "2:30 PM - 3:00 PM"
    end

    test "does not impose it on the booking page a German visitor reads", %{slot: slot} do
      # Same organiser, same instant, attendee-facing surface: the visitor's
      # language decides, so this stays 24-hour.
      assert LocalizationHelpers.format_time_by_locale(slot) == "14:30"
    end
  end

  describe "an organiser who prefers 24h while reading English" do
    setup do
      Gettext.put_locale(TymeslotWeb.Gettext, "en")
      %{chosen: TimeFormat.resolve("24h", "en"), slot: ~U[2026-01-05 14:30:00Z]}
    end

    test "sees their own dashboard on the clock they chose", %{chosen: chosen, slot: slot} do
      m = meeting(slot, ~U[2026-01-05 15:00:00Z])

      assert Helpers.format_meeting_time(m, "Etc/UTC", chosen) == "14:30 - 15:00"
    end

    test "does not impose it on the booking page an English visitor reads", %{slot: slot} do
      assert LocalizationHelpers.format_time_by_locale(slot) == "02:30 PM"
    end
  end

  describe "the booking page across languages" do
    test "follows each visitor's own language, never a stored preference" do
      slot = ~U[2026-01-05 14:30:00Z]

      expected = %{
        "en" => "02:30 PM",
        "de" => "14:30",
        "fr" => "14:30",
        "it" => "14:30",
        "uk" => "14:30"
      }

      for {locale, want} <- expected do
        Gettext.put_locale(TymeslotWeb.Gettext, locale)

        assert LocalizationHelpers.format_time_by_locale(slot) == want,
               "expected #{locale} booking page to render #{want}"
      end
    end
  end
end
