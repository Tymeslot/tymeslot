defmodule Tymeslot.Meetings.AttendeeNotifications.ChangeSummaryTest do
  use ExUnit.Case, async: true
  @moduletag :unit
  @moduletag :meetings
  @moduletag :notifications

  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary

  test "any_changes?/1 is true when fields changed" do
    assert ChangeSummary.any_changes?(%ChangeSummary{changed_fields: [:title]})
  end

  test "any_changes?/1 is true when attendees changed" do
    assert ChangeSummary.any_changes?(%ChangeSummary{added_attendees: [:a]})
    assert ChangeSummary.any_changes?(%ChangeSummary{removed_attendees: [:a]})
  end

  test "any_changes?/1 is false for empty summary" do
    refute ChangeSummary.any_changes?(%ChangeSummary{})
  end
end
