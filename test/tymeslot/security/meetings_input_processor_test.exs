defmodule Tymeslot.Security.MeetingsInputProcessorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Ecto.UUID
  alias Tymeslot.Security.MeetingsInputProcessor

  describe "validate_filter_input/2" do
  @moduletag :security
    test "accepts valid filter options" do
      assert {:ok, %{"filter" => "upcoming"}} =
               MeetingsInputProcessor.validate_filter_input(%{"filter" => "upcoming"})

      assert {:ok, %{"filter" => "past"}} =
               MeetingsInputProcessor.validate_filter_input(%{"filter" => "past"})

      assert {:ok, %{"filter" => "cancelled"}} =
               MeetingsInputProcessor.validate_filter_input(%{"filter" => "cancelled"})
    end

    test "rejects missing filter" do
      assert {:error, errors} = MeetingsInputProcessor.validate_filter_input(%{})
      assert errors[:filter] == ["Filter is required"]
    end

    test "rejects invalid filter option" do
      assert {:error, errors} =
               MeetingsInputProcessor.validate_filter_input(%{"filter" => "invalid"})

      assert errors[:filter] == ["Invalid filter option"]
    end

    test "rejects input with sanitization changes" do
      assert {:error, errors} =
               MeetingsInputProcessor.validate_filter_input(%{"filter" => "upcoming<script>"})

      assert errors[:filter] == ["Invalid characters in filter"]
    end
  end

  describe "validate_meeting_id_input/2" do
    test "accepts valid UUID" do
      uuid = UUID.generate()

      assert {:ok, %{"id" => ^uuid}} =
               MeetingsInputProcessor.validate_meeting_id_input(%{"id" => uuid})
    end

    test "rejects missing meeting id" do
      assert {:error, errors} = MeetingsInputProcessor.validate_meeting_id_input(%{})
      assert errors[:id] == ["Meeting ID is required"]
    end

    test "rejects invalid UUID format" do
      assert {:error, errors} =
               MeetingsInputProcessor.validate_meeting_id_input(%{"id" => "not-a-uuid"})

      assert errors[:id] == ["Invalid meeting ID format"]
    end

    test "rejects non-string meeting id" do
      assert {:error, errors} = MeetingsInputProcessor.validate_meeting_id_input(%{"id" => 123})
      assert errors[:id] == ["Meeting ID must be a string"]
    end
  end
end
