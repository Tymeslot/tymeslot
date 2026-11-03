defmodule Tymeslot.MeetingTypes.DuplicateMeetingTypeTest do
  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CustomFields.FieldDefinition
  alias Tymeslot.MeetingTypes

  setup do
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  describe "duplicate_meeting_type/1" do
    test "copies the settings under a (copy) name, switched off" do
      user = insert(:user)
      schedule_profile = insert(:profile, user: user)
      schedule = insert(:availability_schedule, profile: schedule_profile)

      source =
        insert(:meeting_type,
          user: user,
          name: "Strategy Session",
          description: "An hour on the plan",
          duration_minutes: 60,
          extra_lengths_minutes: [30],
          icon: "hero-rocket-launch",
          availability_schedule: schedule,
          reminder_config: [%{"value" => 1, "unit" => "hours"}],
          max_bookings_per_day: 3,
          requires_approval: true,
          approval_window_hours: 24,
          locations: [in_person_location([])],
          custom_fields: [
            %FieldDefinition{id: "company", type: "short_text", label: "Company", position: 0}
          ]
        )

      assert {:ok, copy} = MeetingTypes.duplicate_meeting_type(source)

      assert copy.id != source.id
      assert copy.name == "Strategy Session (copy)"
      assert copy.is_active == false
      assert copy.description == "An hour on the plan"
      assert copy.duration_minutes == 60
      assert copy.extra_lengths_minutes == [30]
      assert copy.icon == "hero-rocket-launch"
      assert copy.availability_schedule_id == schedule.id
      assert copy.reminder_config == [%{"value" => 1, "unit" => "hours"}]
      assert copy.max_bookings_per_day == 3
      assert copy.requires_approval == true
      assert copy.approval_window_hours == 24
      assert [%{kind: :in_person}] = copy.locations
      assert [%{id: "company", label: "Company"}] = copy.custom_fields

      # The source is untouched.
      reloaded = MeetingTypes.get_meeting_type(source.id, user.id)
      assert reloaded.name == "Strategy Session"
      assert reloaded.is_active == true
    end

    test "derives the video settings from the copied video location" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: true)

      source =
        insert(:meeting_type,
          user: user,
          allow_video: true,
          video_integration: integration,
          locations: [video_location(integration)]
        )

      assert {:ok, copy} = MeetingTypes.duplicate_meeting_type(source)
      assert copy.allow_video == true
      assert copy.video_integration_id == integration.id
      assert [%{kind: :video, video_integration_ids: [id]}] = copy.locations
      assert id == integration.id
    end

    test "refuses a copy whose video provider has since been disconnected" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: false)

      source =
        insert(:meeting_type,
          user: user,
          allow_video: true,
          video_integration: integration,
          locations: [video_location(integration)]
        )

      assert {:error, _reason} = MeetingTypes.duplicate_meeting_type(source)
      assert length(MeetingTypes.get_all_meeting_types(user.id)) == 1
    end

    test "picks the next free name when a copy already exists" do
      user = insert(:user)
      source = insert(:meeting_type, user: user, name: "Intro")
      insert(:meeting_type, user: user, name: "Intro (copy)")

      assert {:ok, copy} = MeetingTypes.duplicate_meeting_type(source)
      assert copy.name == "Intro (copy) 2"
    end

    test "shortens a long source name so the copy stays within the limit" do
      user = insert(:user)
      long_name = String.duplicate("a", 100)
      source = insert(:meeting_type, user: user, name: long_name)

      assert {:ok, copy} = MeetingTypes.duplicate_meeting_type(source)
      assert String.length(copy.name) == 100
      assert String.ends_with?(copy.name, " (copy)")
    end

    test "drops a private type's custom slug, so its secret link reaches the source alone" do
      user = insert(:user)
      source = insert(:meeting_type, user: user, name: "VIP", is_private: true, slug: "x7k2q9")

      assert {:ok, copy} = MeetingTypes.duplicate_meeting_type(source)
      assert copy.slug == nil
      assert copy.is_private == true
      assert MeetingTypes.effective_slug(copy) == "vip-copy"
    end

    test "refuses a copy of a feature the owner's plan no longer includes" do
      setup_config(:tymeslot, feature_access_checker: __MODULE__.DenyAccessChecker)
      user = insert(:user)

      source =
        insert(:meeting_type,
          user: user,
          custom_fields: [
            %FieldDefinition{id: "company", type: "short_text", label: "Company", position: 0}
          ]
        )

      assert {:error, :insufficient_plan} = MeetingTypes.duplicate_meeting_type(source)
      assert length(MeetingTypes.get_all_meeting_types(user.id)) == 1
    end
  end

  defmodule DenyAccessChecker do
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :custom_questions_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end
end
