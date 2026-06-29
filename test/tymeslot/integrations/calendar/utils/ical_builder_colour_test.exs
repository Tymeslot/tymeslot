defmodule Tymeslot.Integrations.Calendar.ICalBuilderColourTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder

  # The per-event colour override is synced to CalDAV as the RFC 7986 COLOR
  # property. The CalDAV write path goes through build_simple_event/2, so the
  # COLOR line must be wired in there. The canonical `:colour` is a Tymeslot
  # palette key mapped to a CSS3 colour name at the boundary.
  describe "build_simple_event/2 — colour" do
    test "emits a COLOR line from a palette colour key" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        colour: "tomato"
      }

      ical = ICalBuilder.build_simple_event("uid-col-1", event_data)

      assert String.contains?(ical, "COLOR:tomato")
    end

    test "maps a palette key to its CSS3 colour name" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        colour: "peacock"
      }

      ical = ICalBuilder.build_simple_event("uid-col-2", event_data)

      assert String.contains?(ical, "COLOR:teal")
    end

    test "emits no COLOR line when no colour override is set" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z]
      }

      ical = ICalBuilder.build_simple_event("uid-col-3", event_data)

      refute String.contains?(ical, "COLOR:")
    end

    test "emits no COLOR line for an unrecognised colour value" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2024-01-15 10:00:00Z],
        end_time: ~U[2024-01-15 11:00:00Z],
        colour: "11"
      }

      ical = ICalBuilder.build_simple_event("uid-col-4", event_data)

      refute String.contains?(ical, "COLOR:")
    end
  end
end
