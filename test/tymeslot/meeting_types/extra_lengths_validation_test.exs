defmodule Tymeslot.MeetingTypes.ExtraLengthsValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.FormMapper
  alias Tymeslot.MeetingTypes.InputValidation
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  defp changeset(attrs) do
    user = insert(:user)

    MeetingTypeSchema.changeset(
      %MeetingTypeSchema{},
      Map.merge(%{name: "Video call", duration_minutes: 30, user_id: user.id}, attrs)
    )
  end

  describe "the schema" do
    test "accepts further durations within the range" do
      assert changeset(%{extra_lengths_minutes: [15, 60, 120]}).valid?
    end

    test "refuses a length outside the allowed range" do
      refute changeset(%{extra_lengths_minutes: [600]}).valid?
      refute changeset(%{extra_lengths_minutes: [0]}).valid?
    end

    test "refuses a length offered twice, including the primary one" do
      refute changeset(%{extra_lengths_minutes: [60, 60]}).valid?
      refute changeset(%{extra_lengths_minutes: [30]}).valid?
    end

    test "refuses more than eight lengths in total" do
      assert changeset(%{extra_lengths_minutes: [15, 45, 60, 90, 120, 150, 180]}).valid?
      refute changeset(%{extra_lengths_minutes: [15, 45, 60, 90, 120, 150, 180, 210]}).valid?
    end
  end

  describe "the form validation" do
    test "reads the index-keyed map the form posts, in index order" do
      assert {:ok, ["60", "15"]} =
               InputValidation.validate_field(
                 :extra_lengths,
                 {%{"1" => "15", "0" => "60"}, "30"},
                 %{}
               )
    end

    test "names what is wrong with an entry" do
      assert {:error, %{extra_lengths: message}} =
               InputValidation.validate_field(:extra_lengths, {["abc"], "30"}, %{})

      assert message =~ "number of minutes"

      assert {:error, %{extra_lengths: message}} =
               InputValidation.validate_field(:extra_lengths, {["42"], "30"}, %{})

      assert message =~ "divisible by 5"

      assert {:error, %{extra_lengths: message}} =
               InputValidation.validate_field(:extra_lengths, {["30"], "30"}, %{})

      assert message =~ "only be offered once"
    end

    test "is part of validating the whole form" do
      params = %{
        "name" => "Video call",
        "duration" => "30",
        "extra_lengths" => ["30"],
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, %{extra_lengths: _message}} =
               InputValidation.validate_meeting_type_form(params)
    end
  end

  describe "mapping the form to attributes" do
    @ui_state %{
      selected_icon: "none",
      meeting_mode: "personal",
      selected_video_integration_id: nil
    }

    test "turns the posted lengths into minutes" do
      params = %{"name" => "Video call", "duration" => "30", "extra_lengths" => ["60", "15"]}

      assert {:ok, %{extra_lengths_minutes: [60, 15]}} =
               FormMapper.build_attrs(params, @ui_state)
    end

    test "leaves the lengths alone when the form did not post them" do
      params = %{"name" => "Video call", "duration" => "30"}

      assert {:ok, attrs} = FormMapper.build_attrs(params, @ui_state)
      refute Map.has_key?(attrs, :extra_lengths_minutes)
    end
  end
end
