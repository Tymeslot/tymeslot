defmodule Tymeslot.MeetingTypes.TargetCalendarStatusTest do
  @moduledoc """
  Tests for `Tymeslot.MeetingTypes.target_calendar_status/1,2`, the check
  behind the dashboard's warning that a meeting type's stored booking target
  can no longer accept the booking.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  defp entries(attrs_list), do: Enum.map(attrs_list, &CalendarEntry.normalize/1)

  defp meeting_type(calendar_list, target_calendar_id) do
    %MeetingTypeSchema{
      target_calendar_id: target_calendar_id,
      calendar_integration: %CalendarIntegrationSchema{calendar_list: calendar_list}
    }
  end

  describe "target_calendar_status/2" do
    test "is :ok while the stored target is still writable" do
      calendars =
        entries([
          %{id: "cal-1", name: "Work", selected: true, read_only: false},
          %{id: "cal-2", name: "Shared", selected: true, read_only: true}
        ])

      assert MeetingTypes.target_calendar_status(calendars, "cal-1") == :ok
    end

    test "is :read_only once the provider marks the stored target unwritable" do
      calendars =
        entries([
          %{id: "cal-1", name: "Work", selected: true, read_only: false},
          %{id: "cal-2", name: "Shared", selected: true, read_only: true}
        ])

      assert MeetingTypes.target_calendar_status(calendars, "cal-2") == :read_only
    end

    test "is :missing once the stored target is gone from the account" do
      calendars = entries([%{id: "cal-1", name: "Work", selected: true, read_only: false}])

      assert MeetingTypes.target_calendar_status(calendars, "cal-gone") == :missing
    end

    test "is :ok for a writable target the host has since deselected" do
      calendars = entries([%{id: "cal-1", name: "Work", selected: false, read_only: false}])

      assert MeetingTypes.target_calendar_status(calendars, "cal-1") == :ok
    end

    test "matches CalDAV ids across percent-encoding differences" do
      calendars =
        entries([
          %{
            id: "https://dav.example.com/calendars/user/Shared%20Team/",
            name: "Shared Team",
            selected: true,
            read_only: false
          }
        ])

      assert MeetingTypes.target_calendar_status(
               calendars,
               "https://dav.example.com/calendars/user/Shared Team/"
             ) == :ok
    end

    test "reports a read-only CalDAV target through the same encoding-tolerant match" do
      calendars =
        entries([
          %{
            id: "https://dav.example.com/calendars/user/Shared%20Team/",
            name: "Shared Team",
            selected: true,
            read_only: true
          }
        ])

      assert MeetingTypes.target_calendar_status(
               calendars,
               "https://dav.example.com/calendars/user/Shared Team/"
             ) == :read_only
    end

    test "is :ok when the calendar list has never been populated" do
      assert MeetingTypes.target_calendar_status([], "cal-1") == :ok
      assert MeetingTypes.target_calendar_status(nil, "cal-1") == :ok
    end

    test "is :ok when no target calendar is stored" do
      calendars = entries([%{id: "cal-1", name: "Work", selected: true, read_only: true}])

      assert MeetingTypes.target_calendar_status(calendars, nil) == :ok
      assert MeetingTypes.target_calendar_status(calendars, "") == :ok
    end
  end

  describe "target_calendar_status/1" do
    test "reads the stored target off the meeting type's preloaded integration" do
      calendars =
        entries([
          %{id: "cal-1", name: "Work", selected: true, read_only: false},
          %{id: "cal-2", name: "Shared", selected: true, read_only: true}
        ])

      assert MeetingTypes.target_calendar_status(meeting_type(calendars, "cal-1")) == :ok
      assert MeetingTypes.target_calendar_status(meeting_type(calendars, "cal-2")) == :read_only
      assert MeetingTypes.target_calendar_status(meeting_type(calendars, "cal-3")) == :missing
    end

    test "is :ok when the meeting type overrides nothing" do
      assert MeetingTypes.target_calendar_status(%MeetingTypeSchema{}) == :ok
    end

    test "is :ok when the calendar integration is not preloaded" do
      type = %MeetingTypeSchema{target_calendar_id: "cal-2"}

      assert %Ecto.Association.NotLoaded{} = type.calendar_integration
      assert MeetingTypes.target_calendar_status(type) == :ok
    end
  end
end
