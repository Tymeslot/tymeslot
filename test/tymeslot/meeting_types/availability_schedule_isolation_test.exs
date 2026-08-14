defmodule Tymeslot.MeetingTypes.AvailabilityScheduleIsolationTest do
  @moduledoc """
  A meeting type may only point at an availability schedule its own host owns.

  The picker lists nothing else, so reaching these cases needs a forged event —
  which is the point: the schema's foreign key proves the referenced schedule
  exists, not who owns it, and the resolved schedule goes on to decide what the
  public booking page offers.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes

  setup do
    user_a = insert(:user)
    user_b = insert(:user)
    profile_a = insert(:profile, user: user_a)
    profile_b = insert(:profile, user: user_b)

    %{
      user_b: user_b,
      foreign_schedule: insert(:availability_schedule, profile: profile_a),
      own_schedule: insert(:availability_schedule, profile: profile_b)
    }
  end

  describe "availability schedule ownership" do
    test "rejects a schedule belonging to another host", %{
      user_b: user_b,
      foreign_schedule: foreign_schedule
    } do
      assert {:error, :invalid_availability_schedule} =
               create_with_schedule(user_b, foreign_schedule.id)
    end

    test "accepts the host's own schedule", %{user_b: user_b, own_schedule: own_schedule} do
      assert {:ok, meeting_type} = create_with_schedule(user_b, own_schedule.id)
      assert meeting_type.availability_schedule_id == own_schedule.id
    end

    test "accepts a blank schedule, which follows the default", %{user_b: user_b} do
      assert {:ok, meeting_type} = create_with_schedule(user_b, "")
      assert meeting_type.availability_schedule_id == nil
    end

    test "rejects a schedule that does not exist", %{user_b: user_b} do
      assert {:error, :invalid_availability_schedule} = create_with_schedule(user_b, 0)
    end

    test "rejects a schedule id that is not a number", %{user_b: user_b} do
      assert {:error, :invalid_availability_schedule} = create_with_schedule(user_b, "nonsense")
    end
  end

  defp create_with_schedule(user, schedule_id) do
    form_params = %{
      "name" => "Cross-User Schedule",
      "duration" => "30",
      "description" => "Points at a schedule",
      "is_active" => "true",
      "availability_schedule_id" => to_string(schedule_id)
    }

    ui_state = %{
      meeting_mode: "in_person",
      selected_icon: "hero-clock",
      selected_video_integration_id: nil
    }

    MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
  end
end
