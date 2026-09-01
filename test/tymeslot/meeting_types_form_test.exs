defmodule Tymeslot.MeetingTypesFormTest do
  @moduledoc """
  Form-driven tests for the MeetingTypes context module.
  Covers `create_meeting_type_from_form/3` and `update_meeting_type_from_form/3`,
  including custom-field preservation and feature gating for custom questions
  and paid meetings.
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

    defmodule CountingDenyPaymentsChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :meeting_payments) do
        Agent.update(__MODULE__, &(&1 + 1))
        {:error, :pro_required}
      end

      def check_access(_user_id, _feature), do: :ok
    end

    setup do
      setup_config(:tymeslot, feature_access_checker: DenyPaymentsChecker)
      :ok
    end

    test "checks meeting_payments access exactly once on the denied path" do
      {:ok, _pid} = Agent.start_link(fn -> 0 end, name: CountingDenyPaymentsChecker)
      setup_config(:tymeslot, feature_access_checker: CountingDenyPaymentsChecker)
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

      assert Agent.get(CountingDenyPaymentsChecker, & &1) == 1
      Agent.stop(CountingDenyPaymentsChecker)
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
