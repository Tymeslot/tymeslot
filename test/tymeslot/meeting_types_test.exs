defmodule Tymeslot.MeetingTypesTest do
  @moduledoc """
  Core CRUD tests for the MeetingTypes context module.
  Focuses on basic create, read, update, delete, toggle, and reorder operations.

  Form-driven creation/update and feature gating live in
  `Tymeslot.MeetingTypesFormTest`.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

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

    test "emits booking-page-published telemetry on first publish for a user with a username" do
      user = insert(:user)
      insert(:profile, user: user, username: "host", booking_theme: "2")

      test_pid = self()

      :telemetry.attach(
        "test-booking-page-published",
        [:tymeslot, :booking_page, :published],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-booking-page-published") end)

      attrs = %{
        name: "Quick Chat",
        duration_minutes: 15,
        icon: "hero-bolt",
        is_active: true,
        user_id: user.id
      }

      assert {:ok, _meeting_type} = MeetingTypes.create_meeting_type(attrs)

      assert_received {:telemetry, %{count: 1}, %{theme: "2"}}
    end
  end

  # =====================================
  # Publishing via default meeting types
  # =====================================

  describe "when default meeting types are created" do
    test "stamps the booking page as published for a user with a username" do
      user = insert(:user)
      insert(:profile, user: user, username: "host")

      assert {:ok, defaults} = MeetingTypes.create_default_meeting_types(user.id)
      assert defaults != []

      assert %DateTime{} = Profiles.get_profile(user.id).booking_page_published_at
    end

    test "does not stamp the booking page when the user has no username" do
      user = insert(:user)
      insert(:profile, user: user, username: nil)

      assert {:ok, defaults} = MeetingTypes.create_default_meeting_types(user.id)
      assert defaults != []

      assert Profiles.get_profile(user.id).booking_page_published_at == nil
    end

    test "emits the publish telemetry once even though several defaults are created" do
      user = insert(:user)
      insert(:profile, user: user, username: "host", booking_theme: "2")

      test_pid = self()

      :telemetry.attach(
        "test-default-publish",
        [:tymeslot, :booking_page, :published],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-default-publish") end)

      assert {:ok, defaults} = MeetingTypes.create_default_meeting_types(user.id)
      assert defaults != []

      assert_received {:telemetry, %{count: 1}, %{theme: "2"}}
      refute_received {:telemetry, _measurements, _metadata}
    end
  end

  # =====================================
  # Activation-triggered publication
  # =====================================

  describe "when an inactive meeting type is activated via toggle_meeting_type_status/2" do
    test "stamps booking_page_published_at for a user with a username" do
      user = insert(:user)
      insert(:profile, user: user, username: "host")
      meeting_type = insert(:meeting_type, user: user, is_active: false)

      assert {:ok, _updated} =
               MeetingTypes.toggle_meeting_type_status(meeting_type, %{is_active: true})

      assert %DateTime{} = Profiles.get_profile(user.id).booking_page_published_at
    end

    test "does not stamp when user has no username" do
      user = insert(:user)
      insert(:profile, user: user, username: nil)
      meeting_type = insert(:meeting_type, user: user, is_active: false)

      assert {:ok, _updated} =
               MeetingTypes.toggle_meeting_type_status(meeting_type, %{is_active: true})

      assert Profiles.get_profile(user.id).booking_page_published_at == nil
    end

    test "is a no-op when page is already published" do
      user = insert(:user)
      published_at = ~U[2024-01-01 00:00:00Z]

      insert(:profile,
        user: user,
        username: "host",
        booking_page_published_at: published_at
      )

      meeting_type = insert(:meeting_type, user: user, is_active: false)

      assert {:ok, _updated} =
               MeetingTypes.toggle_meeting_type_status(meeting_type, %{is_active: true})

      assert Profiles.get_profile(user.id).booking_page_published_at == published_at
    end
  end

  # =====================================
  # has_active_meeting_types? Behaviors
  # =====================================

  describe "has_active_meeting_types?/1" do
    test "returns true when the user has an active meeting type" do
      user = insert(:user)
      insert(:meeting_type, user: user, is_active: true)

      assert MeetingTypes.has_active_meeting_types?(user.id) == true
    end

    test "returns false when the user has only an inactive meeting type" do
      user = insert(:user)
      insert(:meeting_type, user: user, is_active: false)

      assert MeetingTypes.has_active_meeting_types?(user.id) == false
    end

    test "returns false when the user has no meeting types" do
      user = insert(:user)

      assert MeetingTypes.has_active_meeting_types?(user.id) == false
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
end
