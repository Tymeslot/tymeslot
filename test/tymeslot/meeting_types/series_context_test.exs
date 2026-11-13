defmodule Tymeslot.MeetingTypes.SeriesContextTest do
  @moduledoc """
  The series rules and the Pro gate through the `Tymeslot.MeetingTypes`
  context functions, against the database.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  defmodule DenyChecker do
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :recurring_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  @recurring %{
    series_mode: :recurring,
    series_frequency: :weekly,
    series_interval: 2,
    series_min_occurrences: 4,
    series_max_occurrences: 8
  }

  @flexible %{series_mode: :flexible, series_min_occurrences: 2, series_max_occurrences: 5}

  setup do
    %{user: insert(:user)}
  end

  test "recurring and flexible series types satisfy the database check", %{user: user} do
    recurring = insert(:meeting_type, Map.to_list(Map.put(@recurring, :user, user)))
    flexible = insert(:meeting_type, Map.to_list(Map.put(@flexible, :user, user)))

    assert %{series_mode: :recurring, series_frequency: :weekly, series_interval: 2} =
             Repo.get!(MeetingTypeSchema, recurring.id)

    assert %{series_mode: :flexible, series_frequency: nil, series_max_occurrences: 5} =
             Repo.get!(MeetingTypeSchema, flexible.id)
  end

  test "making a series type invitation-only is refused and changes nothing", %{user: user} do
    type = insert(:meeting_type, Map.to_list(Map.put(@flexible, :user, user)))

    assert {:error, changeset} = MeetingTypes.set_invitation_only(type, true)
    assert {_message, _opts} = changeset.errors[:invitation_only]
    assert Repo.get!(MeetingTypeSchema, type.id).invitation_only == false
  end

  describe "without access to recurring bookings" do
    setup do
      setup_config(:tymeslot, feature_access_checker: DenyChecker)
    end

    test "editing an existing series type succeeds", %{user: user} do
      type = insert(:meeting_type, Map.to_list(Map.put(@flexible, :user, user)))

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_checked(type, %{
                 series_mode: :flexible,
                 series_min_occurrences: 3,
                 series_max_occurrences: 6
               })

      assert updated.series_min_occurrences == 3
    end

    test "enabling a series on a plain type is refused", %{user: user} do
      type = insert(:meeting_type, user: user)

      assert {:error, :recurring_bookings_not_allowed} =
               MeetingTypes.update_meeting_type_checked(type, @flexible)

      assert Repo.get!(MeetingTypeSchema, type.id).series_mode == nil
    end

    test "duplicating a series type is refused", %{user: user} do
      type = insert(:meeting_type, Map.to_list(Map.put(@flexible, :user, user)))

      assert {:error, :recurring_bookings_not_allowed} = MeetingTypes.duplicate_meeting_type(type)
    end
  end
end
