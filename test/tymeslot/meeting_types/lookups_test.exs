defmodule Tymeslot.MeetingTypes.LookupsTest do
  @moduledoc """
  Tests for meeting type lookups and validation utilities.
  Covers duration strings, slug-based lookups, and duration validation.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes

  # =====================================
  # Duration String Behaviors
  # =====================================

  describe "when converting to duration string" do
    test "formats duration in minutes" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "30 Minutes", duration_minutes: 30)

      result = MeetingTypes.to_duration_string(meeting_type)

      assert result == "30-minutes"
    end

    test "handles various durations" do
      user = insert(:user)

      meeting_type_15 =
        insert(:meeting_type, user: user, name: "15 Minutes", duration_minutes: 15)

      meeting_type_60 =
        insert(:meeting_type, user: user, name: "60 Minutes", duration_minutes: 60)

      meeting_type_90 =
        insert(:meeting_type, user: user, name: "90 Minutes", duration_minutes: 90)

      assert MeetingTypes.to_duration_string(meeting_type_15) == "15-minutes"
      assert MeetingTypes.to_duration_string(meeting_type_60) == "60-minutes"
      assert MeetingTypes.to_duration_string(meeting_type_90) == "90-minutes"
    end
  end

  describe "when finding meeting type by slug" do
    test "finds matching meeting type" do
      user = insert(:user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Discovery Call",
          duration_minutes: 30,
          is_active: true
        )

      result = MeetingTypes.find_by_slug(user.id, "discovery-call")

      assert result.id == meeting_type.id
    end

    test "returns nil for non-matching slug" do
      user = insert(:user)

      _meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Discovery Call",
          duration_minutes: 30,
          is_active: true
        )

      result = MeetingTypes.find_by_slug(user.id, "other-call")

      assert result == nil
    end

    test "only finds active meeting types" do
      user = insert(:user)

      _inactive =
        insert(:meeting_type,
          user: user,
          name: "Inactive Call",
          duration_minutes: 30,
          is_active: false
        )

      active =
        insert(:meeting_type,
          user: user,
          name: "Active Call",
          duration_minutes: 45,
          is_active: true
        )

      result_inactive = MeetingTypes.find_by_slug(user.id, "inactive-call")
      result_active = MeetingTypes.find_by_slug(user.id, "active-call")

      assert result_inactive == nil
      assert result_active.id == active.id
    end
  end

  # Keep old tests for find_by_duration_string but update expectations
  describe "when finding meeting type by duration string (deprecated)" do
    test "finds matching meeting type by slug" do
      user = insert(:user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Quick Chat",
          duration_minutes: 30,
          is_active: true
        )

      result = MeetingTypes.find_by_duration_string(user.id, "quick-chat")

      assert result.id == meeting_type.id
    end
  end

  # =====================================
  # Duration Validation Behaviors
  # =====================================

  describe "when validating duration selection" do
    test "accepts valid duration from available types" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30)

      result = MeetingTypes.validate_duration_selection("intro", [meeting_type])

      assert result == :ok
    end

    test "rejects nil duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      assert {:error, :duration_required} =
               MeetingTypes.validate_duration_selection(nil, [meeting_type])
    end

    test "rejects empty duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      assert {:error, :duration_required} =
               MeetingTypes.validate_duration_selection("", [meeting_type])
    end

    test "rejects duration not in available types" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30)

      assert {:error, :duration_invalid} =
               MeetingTypes.validate_duration_selection("other", [meeting_type])
    end
  end

  describe "when checking duration validity" do
    test "returns true for valid duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Quick", duration_minutes: 45)

      result = MeetingTypes.duration_valid?("quick", [meeting_type])

      assert result == true
    end

    test "returns false for invalid duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Intro")

      result = MeetingTypes.duration_valid?("other", [meeting_type])

      assert result == false
    end

    test "returns false for non-binary duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.duration_valid?(123, [meeting_type])

      assert result == false
    end

    test "returns false for non-list available types" do
      result = MeetingTypes.duration_valid?("30min", nil)

      assert result == false
    end
  end
end
