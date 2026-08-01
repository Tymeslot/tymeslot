defmodule Tymeslot.MeetingTypes.FormProcessingTargetCalendarTest do
  @moduledoc """
  Tests for target-calendar validation in meeting type form processing.
  Extracted from FormProcessingTest to keep individual modules under the
  project line-count limit.

  Covers the persistence-side narrowing to writable calendars (matching the
  picker's `Tymeslot.Integrations.Calendar.writable_calendars/1`) and the
  distinct error surfaced when every calendar selected for an integration is
  read-only.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )
  end

  describe "target calendar writability" do
    test "fails when the target calendar is present in the list but read-only" do
      user = insert(:user)

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          calendar_list: [
            %{"id" => "cal-1", "name" => "Primary", "selected" => true, "read_only" => false},
            %{
              "id" => "cal-2",
              "name" => "Shared (view only)",
              "selected" => true,
              "read_only" => true
            }
          ]
        )

      form_params = %{
        "name" => "Calendar Meeting",
        "duration" => "30",
        "description" => "Calendar scoped meeting",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => "cal-2"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, :target_calendar_invalid} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end

    test "succeeds when the target calendar is selected and writable" do
      user = insert(:user)

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          calendar_list: [
            %{"id" => "cal-1", "name" => "Primary", "selected" => true, "read_only" => false}
          ]
        )

      form_params = %{
        "name" => "Calendar Meeting",
        "duration" => "30",
        "description" => "Calendar scoped meeting",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => "cal-1"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.target_calendar_id == "cal-1"
    end

    test "fails with a distinct, explanatory error when every selected calendar is read-only" do
      user = insert(:user)

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          calendar_list: [
            %{
              "id" => "cal-1",
              "name" => "Shared (view only)",
              "selected" => true,
              "read_only" => true
            }
          ]
        )

      form_params = %{
        "name" => "Calendar Meeting",
        "duration" => "30",
        "description" => "Calendar scoped meeting",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => nil
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, :no_writable_calendars} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end

    test "fails with the ordinary required error when no calendars are selected at all" do
      user = insert(:user)

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          calendar_list: [
            %{"id" => "cal-1", "name" => "Primary", "selected" => false, "read_only" => false}
          ]
        )

      form_params = %{
        "name" => "Calendar Meeting",
        "duration" => "30",
        "description" => "Calendar scoped meeting",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => nil
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, :target_calendar_required} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end
  end
end
