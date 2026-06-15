defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.SubmissionTest do
  use ExUnit.Case, async: true

  @moduletag :meeting_types

  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Submission

  defp base_assigns(overrides) do
    Map.merge(
      %{
        form_data: %{"name" => "Quick Chat", "duration" => "30", "description" => "Hi"},
        type: %{is_active: true},
        meeting_mode: "personal",
        selected_icon: "hero-bolt",
        selected_video_integration_id: nil,
        selected_calendar_integration_id: 7,
        selected_target_calendar_id: "cal-1",
        reminders: [%{value: 30, unit: "minutes"}],
        custom_fields: [],
        custom_questions_allowed: true,
        payments_feature_enabled: false,
        payments_charges_enabled: false,
        payment_required: false,
        payment_price: ""
      },
      overrides
    )
  end

  describe "build_params/1" do
    test "serialises socket assigns into the meeting_type params map" do
      params = Submission.build_params(base_assigns(%{}))

      assert params["name"] == "Quick Chat"
      assert params["duration"] == "30"
      assert params["description"] == "Hi"
      assert params["icon"] == "hero-bolt"
      assert params["is_active"] == "true"
      assert params["meeting_mode"] == "personal"
      assert params["calendar_integration_id"] == "7"
      assert params["target_calendar_id"] == "cal-1"
      assert params["reminder_config"] == [%{"value" => "30", "unit" => "minutes"}]
      assert params["custom_fields"] == []
    end

    test "represents an unset integration id as an empty string" do
      params = Submission.build_params(base_assigns(%{selected_video_integration_id: nil}))

      assert params["video_integration_id"] == ""
    end

    test "omits custom_fields entirely when custom questions are not allowed" do
      params =
        Submission.build_params(
          base_assigns(%{
            custom_questions_allowed: false,
            custom_fields: [%{id: "x", type: "short_text", label: "Co"}]
          })
        )

      refute Map.has_key?(params, "custom_fields")
    end

    test "includes payment fields only when charges are enabled" do
      params =
        Submission.build_params(
          base_assigns(%{
            payments_feature_enabled: true,
            payments_charges_enabled: true,
            payment_required: true,
            payment_price: "12.00"
          })
        )

      assert params["payment_required"] == "true"
      assert params["price"] == "12.00"
    end

    test "omits payment fields when the host cannot accept charges" do
      params = Submission.build_params(base_assigns(%{payments_feature_enabled: true}))

      refute Map.has_key?(params, "payment_required")
      refute Map.has_key?(params, "price")
    end
  end
end
