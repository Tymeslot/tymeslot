defmodule Tymeslot.Integrations.Calendar.ICalBuilderPropertyTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ICalBuilder

  describe "build_event/1 — atom status and transparency" do
    test "upcases atom :tentative to STATUS:TENTATIVE" do
      event_data = %{
        summary: "Maybe",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        status: :tentative
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "STATUS:TENTATIVE")
    end

    test "upcases atom :confirmed to STATUS:CONFIRMED" do
      event_data = %{
        summary: "Confirmed",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        status: :confirmed
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "STATUS:CONFIRMED")
    end

    test "silently skips an invalid atom status" do
      event_data = %{
        summary: "Bad Status",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        status: :unknown_status
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "STATUS:")
    end

    test "upcases atom :opaque to TRANSP:OPAQUE" do
      event_data = %{
        summary: "Busy",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        transparency: :opaque
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "TRANSP:OPAQUE")
    end

    test "upcases atom :transparent to TRANSP:TRANSPARENT" do
      event_data = %{
        summary: "Free",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        transparency: :transparent
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "TRANSP:TRANSPARENT")
    end

    test "silently skips an invalid atom transparency" do
      event_data = %{
        summary: "Bad Transparency",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        transparency: :unknown_transparency
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "TRANSP:")
    end
  end

  describe "build_event/1 — visibility producing CLASS property" do
    test "emits CLASS:PRIVATE for :private visibility" do
      event_data = %{
        summary: "Private Event",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :private
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:PRIVATE")
    end

    test "emits CLASS:PUBLIC for :public visibility" do
      event_data = %{
        summary: "Public Event",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :public
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:PUBLIC")
    end

    test "emits CLASS:CONFIDENTIAL for :confidential visibility" do
      event_data = %{
        summary: "Confidential Event",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :confidential
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:CONFIDENTIAL")
    end

    test "accepts string visibility values" do
      event_data = %{
        summary: "String Visibility",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: "private"
      }

      ical = ICalBuilder.build_event(event_data)

      assert String.contains?(ical, "CLASS:PRIVATE")
    end

    test "silently skips an invalid visibility value" do
      event_data = %{
        summary: "Bad Visibility",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :internal
      }

      ical = ICalBuilder.build_event(event_data)

      refute String.contains?(ical, "CLASS:")
    end
  end
end
