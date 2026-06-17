defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.InitTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Init

  describe "build_form_data/1" do
    test "returns defaults when given nil" do
      assert Init.build_form_data(nil) == %{
               "name" => "",
               "duration" => "30",
               "description" => "",
               "icon" => "none"
             }
    end

    test "extracts values from a meeting type struct" do
      type = %{name: "Standup", duration_minutes: 15, description: "Daily sync", icon: "calendar"}

      assert Init.build_form_data(type) == %{
               "name" => "Standup",
               "duration" => "15",
               "description" => "Daily sync",
               "icon" => "calendar"
             }
    end

    test "falls back to defaults for nil fields in struct" do
      type = %{name: nil, duration_minutes: nil, description: nil, icon: nil}

      result = Init.build_form_data(type)
      assert result["name"] == ""
      assert result["duration"] == "30"
      assert result["description"] == ""
      assert result["icon"] == "none"
    end
  end

  describe "get_selected_icon/1" do
    test "returns none for nil" do
      assert Init.get_selected_icon(nil) == "none"
    end

    test "returns the icon when present and non-empty" do
      assert Init.get_selected_icon(%{icon: "calendar"}) == "calendar"
    end

    test "returns none for empty icon string" do
      assert Init.get_selected_icon(%{icon: ""}) == "none"
    end

    test "returns none when icon key is missing" do
      assert Init.get_selected_icon(%{}) == "none"
    end
  end

  describe "get_allow_guests/1" do
    test "returns false for nil" do
      assert Init.get_allow_guests(nil) == false
    end

    test "returns true when allow_guests is true" do
      assert Init.get_allow_guests(%{allow_guests: true}) == true
    end

    test "returns false when allow_guests is false" do
      assert Init.get_allow_guests(%{allow_guests: false}) == false
    end

    test "returns false when allow_guests key is absent" do
      assert Init.get_allow_guests(%{}) == false
    end
  end

  describe "get_meeting_mode/1" do
    test "returns personal for nil" do
      assert Init.get_meeting_mode(nil) == "personal"
    end

    test "returns video when allow_video is true" do
      assert Init.get_meeting_mode(%{allow_video: true}) == "video"
    end

    test "returns personal when allow_video is false" do
      assert Init.get_meeting_mode(%{allow_video: false}) == "personal"
    end

    test "returns personal when allow_video is not set" do
      assert Init.get_meeting_mode(%{}) == "personal"
    end
  end

  describe "get_video_integration_id/1" do
    test "returns nil for nil" do
      assert Init.get_video_integration_id(nil) == nil
    end

    test "returns nil when video_integration_id is nil" do
      assert Init.get_video_integration_id(%{video_integration_id: nil}) == nil
    end

    test "returns integer id directly" do
      assert Init.get_video_integration_id(%{video_integration_id: 42}) == 42
    end

    test "parses binary id to integer" do
      assert Init.get_video_integration_id(%{video_integration_id: "42"}) == 42
    end

    test "returns nil for non-parseable binary id" do
      assert Init.get_video_integration_id(%{video_integration_id: "abc"}) == nil
    end

    test "returns nil when key is missing" do
      assert Init.get_video_integration_id(%{}) == nil
    end
  end

  describe "get_calendar_integration_id/1" do
    test "returns nil for nil" do
      assert Init.get_calendar_integration_id(nil) == nil
    end

    test "returns nil when calendar_integration_id is nil" do
      assert Init.get_calendar_integration_id(%{calendar_integration_id: nil}) == nil
    end

    test "returns the id when present" do
      assert Init.get_calendar_integration_id(%{calendar_integration_id: 7}) == 7
    end
  end

  describe "get_target_calendar_id/1" do
    test "returns nil for nil" do
      assert Init.get_target_calendar_id(nil) == nil
    end

    test "returns nil when target_calendar_id is nil" do
      assert Init.get_target_calendar_id(%{target_calendar_id: nil}) == nil
    end

    test "returns the id when present" do
      assert Init.get_target_calendar_id(%{target_calendar_id: "primary"}) == "primary"
    end
  end

  describe "get_reminders/1" do
    test "returns default reminder for nil" do
      assert Init.get_reminders(nil) == [%{value: 30, unit: "minutes"}]
    end

    test "normalises existing reminder config" do
      type = %{reminder_config: [%{value: 15, unit: "minutes"}, %{value: 1, unit: "hours"}]}

      assert Init.get_reminders(type) == [
               %{value: 15, unit: "minutes"},
               %{value: 1, unit: "hours"}
             ]
    end

    test "filters out invalid reminders from config" do
      type = %{reminder_config: [%{value: 15, unit: "minutes"}, %{value: -1, unit: "invalid"}]}

      assert Init.get_reminders(type) == [%{value: 15, unit: "minutes"}]
    end

    test "returns default for struct without reminder_config" do
      assert Init.get_reminders(%{other_field: true}) == [%{value: 30, unit: "minutes"}]
    end

    test "normalises string-keyed reminder maps" do
      type = %{reminder_config: [%{"value" => 10, "unit" => "minutes"}]}

      assert Init.get_reminders(type) == [%{value: 10, unit: "minutes"}]
    end
  end

  describe "fetch_available_calendars/2" do
    test "returns only calendars marked selected: true" do
      calendars = [
        %{"id" => "cal-1", "name" => "Work", "selected" => true},
        %{"id" => "cal-2", "name" => "Personal", "selected" => false},
        %{"id" => "cal-3", "name" => "Holidays", "selected" => true}
      ]

      integrations = [%{id: 1, calendar_list: calendars}, %{id: 2, calendar_list: []}]

      assert Init.fetch_available_calendars(1, integrations) == [
               %{"id" => "cal-1", "name" => "Work", "selected" => true},
               %{"id" => "cal-3", "name" => "Holidays", "selected" => true}
             ]
    end

    test "returns empty list when no calendar is selected" do
      calendars = [
        %{"id" => "cal-1", "name" => "Work", "selected" => false},
        %{"id" => "cal-2", "name" => "Personal", "selected" => false}
      ]

      integrations = [%{id: 1, calendar_list: calendars}]

      assert Init.fetch_available_calendars(1, integrations) == []
    end

    test "tolerates atom-keyed selected flags" do
      calendars = [%{id: "cal-1", name: "Work", selected: true}, %{id: "cal-2", selected: false}]
      integrations = [%{id: 1, calendar_list: calendars}]

      assert Init.fetch_available_calendars(1, integrations) ==
               [%{id: "cal-1", name: "Work", selected: true}]
    end

    test "returns empty list when no integration matches" do
      integrations = [%{id: 1, calendar_list: [%{"id" => "cal-1", "selected" => true}]}]

      assert Init.fetch_available_calendars(999, integrations) == []
    end

    test "returns empty list when integration has nil calendar_list" do
      integrations = [%{id: 1, calendar_list: nil}]

      assert Init.fetch_available_calendars(1, integrations) == []
    end

    test "returns empty list for empty integrations" do
      assert Init.fetch_available_calendars(1, []) == []
    end
  end
end
