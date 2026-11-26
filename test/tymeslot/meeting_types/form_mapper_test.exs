defmodule Tymeslot.MeetingTypes.FormMapperTest do
  use ExUnit.Case, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.FormMapper

  @ui_state %{
    selected_icon: "none",
    meeting_mode: "personal",
    selected_video_integration_id: nil
  }

  test "a paid group type stays paid" do
    params = %{
      "name" => "Workshop",
      "duration" => "60",
      "max_participants" => "8",
      "payment_required" => "true",
      "price" => "25.00"
    }

    assert {:ok, attrs} = FormMapper.build_attrs(params, @ui_state, "USD")
    assert attrs.max_participants == 8
    assert attrs.payment_required == true
    assert attrs.price_cents == 2500
  end

  test "a group form without payment fields leaves the stored payment alone" do
    params = %{"name" => "Workshop", "duration" => "60", "max_participants" => "8"}

    assert {:ok, attrs} = FormMapper.build_attrs(params, @ui_state, "USD")
    refute Map.has_key?(attrs, :payment_required)
    refute Map.has_key?(attrs, :price_cents)
  end
end
