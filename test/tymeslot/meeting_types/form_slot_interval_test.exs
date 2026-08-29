defmodule Tymeslot.MeetingTypes.FormSlotIntervalTest do
  @moduledoc """
  Tests that a meeting type's booking slot interval survives the form path.

  The interval is optional, and its absence is load-bearing: NULL means "use the
  meeting type's own duration", which is what the slot generator and the theme
  grouping both branch on. A blank form field must therefore persist NULL rather
  than an explicit copy of the duration, or two meeting types with identical
  settings would offer different grids.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes

  setup do
    # Mirrors FormProcessingTest: pin the access checker to Core's default so
    # that SaaS config compiled alongside Core cannot gate these behind a
    # subscription check.
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )
  end

  describe "slot interval through the meeting type form" do
    test "leaves slot_interval_minutes NULL when the form offers no interval" do
      user = insert(:user)

      form_params = %{
        "name" => "Consultation",
        "duration" => "60",
        "slot_interval" => "",
        "description" => "One hour consultation",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      # NULL, never an explicit copy of the duration: the slot generator and the
      # theme grouping both branch on nil to mean "use the meeting length".
      assert meeting_type.slot_interval_minutes == nil
    end

    test "persists a slot interval finer than the meeting duration" do
      user = insert(:user)

      form_params = %{
        "name" => "Consultation",
        "duration" => "60",
        "slot_interval" => "15",
        "description" => "One hour consultation",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.slot_interval_minutes == 15
    end

    test "rejects a slot interval below the permitted range" do
      user = insert(:user)

      form_params = %{
        "name" => "Consultation",
        "duration" => "60",
        "slot_interval" => "3",
        "description" => "One hour consultation",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, %Ecto.Changeset{} = changeset} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert errors_on(changeset)[:slot_interval_minutes]
    end
  end
end
