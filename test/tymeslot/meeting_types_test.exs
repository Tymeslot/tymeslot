defmodule Tymeslot.MeetingTypesTest do
  @moduledoc """
  Core CRUD tests for the MeetingTypes context module.
  Focuses on basic create, read, update, delete, toggle, and reorder operations.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes

  setup do
    # When the SaaS app is compiled alongside Core, its config sets the
    # FeatureAccessChecker to one that denies non-paying users. Pin to the
    # Core default so domain-level tests are not affected by SaaS gating.
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  # =====================================
  # Retrieving Meeting Types Behaviors
  # =====================================

  describe "when user views their meeting types" do
    test "returns all active meeting types" do
      user = insert(:user)
      active_type = insert(:meeting_type, user: user, is_active: true)
      _inactive_type = insert(:meeting_type, user: user, is_active: false)

      result = MeetingTypes.get_active_meeting_types(user.id)

      assert length(result) == 1
      assert hd(result).id == active_type.id
    end

    test "creates default meeting types if user has none" do
      user = insert(:user)

      # User has no meeting types initially
      result = MeetingTypes.get_active_meeting_types(user.id)

      # Should have created defaults
      assert result != []
    end

    test "defaults do not set calendar integration without booking target" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      _profile = insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      result = MeetingTypes.get_active_meeting_types(user.id)

      assert result != []
      assert Enum.all?(result, &is_nil(&1.calendar_integration_id))
      assert Enum.all?(result, &is_nil(&1.target_calendar_id))
    end

    test "returns all meeting types including inactive ones" do
      user = insert(:user)
      _active_type = insert(:meeting_type, user: user, is_active: true)
      _inactive_type = insert(:meeting_type, user: user, is_active: false)

      result = MeetingTypes.get_all_meeting_types(user.id)

      assert length(result) == 2
    end
  end

  describe "when getting a specific meeting type" do
    test "returns meeting type when it exists for user" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.get_meeting_type(meeting_type.id, user.id)

      assert result.id == meeting_type.id
      assert result.user_id == user.id
    end

    test "returns nil when meeting type does not exist" do
      user = insert(:user)

      result = MeetingTypes.get_meeting_type(999_999, user.id)

      assert result == nil
    end

    test "returns nil when meeting type belongs to different user" do
      user1 = insert(:user)
      user2 = insert(:user)
      meeting_type = insert(:meeting_type, user: user1)

      result = MeetingTypes.get_meeting_type(meeting_type.id, user2.id)

      assert result == nil
    end
  end

  # =====================================
  # Creating Meeting Types Behaviors
  # =====================================

  describe "when creating a meeting type" do
    test "successfully creates with valid attributes" do
      user = insert(:user)

      attrs = %{
        name: "Quick Chat",
        duration_minutes: 15,
        description: "A brief conversation",
        icon: "hero-bolt",
        is_active: true,
        allow_video: false,
        user_id: user.id
      }

      assert {:ok, meeting_type} = MeetingTypes.create_meeting_type(attrs)

      assert meeting_type.name == "Quick Chat"
      assert meeting_type.duration_minutes == 15
      assert meeting_type.is_active == true
    end

    test "fails with missing required fields" do
      user = insert(:user)

      attrs = %{
        user_id: user.id
        # Missing name and duration_minutes
      }

      result = MeetingTypes.create_meeting_type(attrs)

      assert {:error, changeset} = result
      assert changeset.valid? == false
    end
  end

  # =====================================
  # Updating Meeting Types Behaviors
  # =====================================

  describe "when updating a meeting type" do
    test "successfully updates existing meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Old Name")

      assert {:ok, updated} = MeetingTypes.update_meeting_type(meeting_type, %{name: "New Name"})

      assert updated.name == "New Name"
    end

    test "can change duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type(meeting_type, %{duration_minutes: 45})

      assert updated.duration_minutes == 45
    end
  end

  # =====================================
  # Toggling Meeting Type Status Behaviors
  # =====================================

  describe "when toggling meeting type status" do
    test "activates an inactive meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, is_active: false)

      assert {:ok, toggled} = MeetingTypes.toggle_meeting_type(meeting_type.id, user.id)

      assert toggled.is_active == true
    end

    test "deactivates an active meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, is_active: true)

      assert {:ok, toggled} = MeetingTypes.toggle_meeting_type(meeting_type.id, user.id)

      assert toggled.is_active == false
    end

    test "returns not found for non-existent meeting type" do
      user = insert(:user)

      result = MeetingTypes.toggle_meeting_type(999_999, user.id)

      assert {:error, :not_found} = result
    end

    test "returns not found when meeting type belongs to different user" do
      user1 = insert(:user)
      user2 = insert(:user)
      meeting_type = insert(:meeting_type, user: user1)

      result = MeetingTypes.toggle_meeting_type(meeting_type.id, user2.id)

      assert {:error, :not_found} = result
    end
  end

  # =====================================
  # Deleting Meeting Types Behaviors
  # =====================================

  describe "when deleting a meeting type" do
    test "successfully deletes meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      assert {:ok, deleted} = MeetingTypes.delete_meeting_type(meeting_type)

      assert deleted.id == meeting_type.id

      # Verify it's actually deleted
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id) == nil
    end
  end

  # =====================================
  # List Meeting Types Behaviors
  # =====================================

  describe "when listing meeting types" do
    test "returns all meeting types for user" do
      user = insert(:user)
      _type1 = insert(:meeting_type, user: user, is_active: true)
      _type2 = insert(:meeting_type, user: user, is_active: false)

      result = MeetingTypes.list_meeting_types(user.id)

      assert length(result) == 2
    end

    test "creates defaults if user has no meeting types" do
      user = insert(:user)

      result = MeetingTypes.list_meeting_types(user.id)

      assert result != []
    end
  end

  describe "when getting meeting type by ID only" do
    test "returns meeting type when it exists" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.get_meeting_type!(meeting_type.id)

      assert result.id == meeting_type.id
    end

    test "raises when meeting type does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        MeetingTypes.get_meeting_type!(999_999)
      end
    end
  end

  describe "when reordering meeting types" do
    test "reorders meeting types for a user" do
      user = insert(:user)

      mt1 = insert(:meeting_type, user: user, name: "Meeting A", sort_order: 0)
      mt2 = insert(:meeting_type, user: user, name: "Meeting B", sort_order: 1)
      mt3 = insert(:meeting_type, user: user, name: "Meeting C", sort_order: 2)

      # Reorder: B, C, A
      new_order = [mt2.id, mt3.id, mt1.id]

      assert {:ok, _result} = MeetingTypes.reorder_meeting_types(user.id, new_order)

      # Verify new order
      types = MeetingTypes.get_all_meeting_types(user.id)
      assert Enum.at(types, 0).id == mt2.id
      assert Enum.at(types, 1).id == mt3.id
      assert Enum.at(types, 2).id == mt1.id
    end

    test "does not reorder other users' meeting types" do
      user1 = insert(:user)
      user2 = insert(:user)

      mt1 = insert(:meeting_type, user: user1, name: "User1 First", sort_order: 0)
      mt2 = insert(:meeting_type, user: user1, name: "User1 Second", sort_order: 1)

      # Try to reorder user1's types as user2 — rolls back because IDs don't match
      new_order = [mt2.id, mt1.id]
      assert {:error, :partial_reorder} = MeetingTypes.reorder_meeting_types(user2.id, new_order)

      # Verify user1's types remain unchanged
      types = MeetingTypes.get_all_meeting_types(user1.id)
      assert Enum.at(types, 0).id == mt1.id
      assert Enum.at(types, 1).id == mt2.id
    end

    test "handles empty meeting type list" do
      user = insert(:user)

      assert {:ok, _result} = MeetingTypes.reorder_meeting_types(user.id, [])
    end
  end

  describe "to_slug/1" do
    test "produces empty string for special-character-only names" do
      user = insert(:user)

      # Bypass form validation by inserting directly with a special-char name
      {:ok, mt} =
        MeetingTypes.create_meeting_type(%{
          name: "---",
          duration_minutes: 30,
          user_id: user.id
        })

      assert MeetingTypes.to_slug(mt) == ""
    end
  end

  describe "update_meeting_type_from_form/3 custom fields preservation" do
    test "preserves existing custom fields when params omit custom_fields key" do
      user = insert(:user)

      # Create a meeting type with a custom field definition
      {:ok, meeting_type} =
        MeetingTypes.create_meeting_type_from_form(
          user.id,
          %{
            "name" => "With Fields",
            "duration" => "30",
            "description" => "",
            "is_active" => "true",
            "calendar_integration_id" => "",
            "target_calendar_id" => nil,
            "custom_fields" => [
              %{"id" => "f1", "type" => "short_text", "label" => "Company", "required" => true}
            ]
          },
          %{
            meeting_mode: "in_person",
            selected_video_integration_id: nil,
            selected_icon: "none"
          }
        )

      assert length(meeting_type.custom_fields) == 1

      # Update without sending a custom_fields key — existing fields must be preserved
      {:ok, updated} =
        MeetingTypes.update_meeting_type_from_form(
          meeting_type,
          %{
            "name" => "With Fields",
            "duration" => "45",
            "description" => "Updated description",
            "is_active" => "true",
            "calendar_integration_id" => "",
            "target_calendar_id" => nil
            # Deliberately no "custom_fields" key
          },
          %{
            meeting_mode: "in_person",
            selected_video_integration_id: nil,
            selected_icon: "none"
          }
        )

      assert length(updated.custom_fields) == 1
      assert updated.duration_minutes == 45
    end

    test "replaces custom fields when params include an explicit custom_fields key" do
      user = insert(:user)

      {:ok, meeting_type} =
        MeetingTypes.create_meeting_type_from_form(
          user.id,
          %{
            "name" => "Replace Fields",
            "duration" => "30",
            "description" => "",
            "is_active" => "true",
            "calendar_integration_id" => "",
            "target_calendar_id" => nil,
            "custom_fields" => [
              %{"id" => "f1", "type" => "short_text", "label" => "Company", "required" => true}
            ]
          },
          %{
            meeting_mode: "in_person",
            selected_video_integration_id: nil,
            selected_icon: "none"
          }
        )

      assert length(meeting_type.custom_fields) == 1

      # Explicitly pass an empty list — should wipe the existing fields
      {:ok, updated} =
        MeetingTypes.update_meeting_type_from_form(
          meeting_type,
          %{
            "name" => "Replace Fields",
            "duration" => "30",
            "description" => "",
            "is_active" => "true",
            "calendar_integration_id" => "",
            "target_calendar_id" => nil,
            "custom_fields" => []
          },
          %{
            meeting_mode: "in_person",
            selected_video_integration_id: nil,
            selected_icon: "none"
          }
        )

      assert updated.custom_fields == []
    end
  end

  describe "custom_questions feature gating" do
    defmodule DenyAccessChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :custom_questions_allowed), do: {:error, :insufficient_plan}
      def check_access(_user_id, _feature), do: :ok
    end

    setup do
      setup_config(:tymeslot, feature_access_checker: DenyAccessChecker)
      :ok
    end

    test "blocks creation when params include non-empty custom_fields" do
      user = insert(:user)

      assert {:error, :insufficient_plan} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 %{
                   "name" => "Gated",
                   "duration" => "30",
                   "description" => "",
                   "is_active" => "true",
                   "calendar_integration_id" => "",
                   "target_calendar_id" => nil,
                   "custom_fields" => [
                     %{
                       "id" => "f1",
                       "type" => "short_text",
                       "label" => "Company",
                       "required" => true
                     }
                   ]
                 },
                 %{
                   meeting_mode: "in_person",
                   selected_video_integration_id: nil,
                   selected_icon: "none"
                 }
               )
    end

    test "allows creation without a custom_fields key" do
      user = insert(:user)

      assert {:ok, _meeting_type} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 %{
                   "name" => "No Questions",
                   "duration" => "30",
                   "description" => "",
                   "is_active" => "true",
                   "calendar_integration_id" => "",
                   "target_calendar_id" => nil
                 },
                 %{
                   meeting_mode: "in_person",
                   selected_video_integration_id: nil,
                   selected_icon: "none"
                 }
               )
    end

    test "allows update that omits custom_fields, preserving the existing list" do
      user = insert(:user)
      # Bypass the gate by inserting directly — simulates a meeting type that
      # was created while the user had a Pro plan.
      {:ok, meeting_type} =
        MeetingTypes.create_meeting_type(%{
          name: "Has Questions",
          duration_minutes: 30,
          user_id: user.id,
          custom_fields: [
            %{id: "f1", type: "short_text", label: "Company", required: true, position: 0}
          ]
        })

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 %{
                   "name" => "Has Questions",
                   "duration" => "45",
                   "description" => "",
                   "is_active" => "true",
                   "calendar_integration_id" => "",
                   "target_calendar_id" => nil
                 },
                 %{
                   meeting_mode: "in_person",
                   selected_video_integration_id: nil,
                   selected_icon: "none"
                 }
               )

      assert length(updated.custom_fields) == 1
      assert updated.duration_minutes == 45
    end
  end

  describe "meeting_payments feature gating" do
    defmodule DenyPaymentsChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :meeting_payments), do: {:error, :pro_required}
      def check_access(_user_id, _feature), do: :ok
    end

    setup do
      setup_config(:tymeslot, feature_access_checker: DenyPaymentsChecker)
      :ok
    end

    test "rejects a forged payment_required=true create when access is denied" do
      user = insert(:user)

      assert {:error, :pro_required} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 %{
                   "name" => "Forged Paid",
                   "duration" => "30",
                   "description" => "",
                   "is_active" => "true",
                   "calendar_integration_id" => "",
                   "target_calendar_id" => nil,
                   "payment_required" => "true",
                   "price" => "50.00"
                 },
                 %{
                   meeting_mode: "in_person",
                   selected_video_integration_id: nil,
                   selected_icon: "none"
                 }
               )
    end

    test "allows a free (payment_required absent) create when payments are denied" do
      user = insert(:user)

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 %{
                   "name" => "Free Type",
                   "duration" => "30",
                   "description" => "",
                   "is_active" => "true",
                   "calendar_integration_id" => "",
                   "target_calendar_id" => nil
                 },
                 %{
                   meeting_mode: "in_person",
                   selected_video_integration_id: nil,
                   selected_icon: "none"
                 }
               )

      refute meeting_type.payment_required
    end

    test "allows turning a paid type off even when payments are denied" do
      user = insert(:user)
      # Simulate a type created while the host still had access.
      {:ok, meeting_type} =
        MeetingTypes.create_meeting_type(%{
          name: "Was Paid",
          duration_minutes: 30,
          user_id: user.id,
          payment_required: false
        })

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 %{
                   "name" => "Was Paid",
                   "duration" => "30",
                   "description" => "",
                   "is_active" => "true",
                   "calendar_integration_id" => "",
                   "target_calendar_id" => nil,
                   "payment_required" => "false"
                 },
                 %{
                   meeting_mode: "in_person",
                   selected_video_integration_id: nil,
                   selected_icon: "none"
                 }
               )

      refute updated.payment_required
    end
  end
end
