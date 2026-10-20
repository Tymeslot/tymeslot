defmodule TymeslotWeb.Dashboard.CalendarEditMessagesTest do
  @moduledoc "The copy the calendar shows when a change is refused or fails."

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarEditMessages

  test "each refusal has its level and words" do
    assert {:error, "This calendar is read-only." <> _rest} =
             CalendarEditMessages.refusal({:error, :read_only})

    assert {:warning, "Too many edits. Please wait a moment."} =
             CalendarEditMessages.refusal({:error, :rate_limited, "slow down"})

    assert {:warning, "This is a booking. Reschedule or cancel it from Bookings."} =
             CalendarEditMessages.refusal({:error, :booking})
  end

  test "a failed delete says whether it will be retried" do
    assert CalendarEditMessages.delete_failed_message(%{retry: :queued}, false) ==
             "Delete failed - queued to retry on next sync"

    assert CalendarEditMessages.delete_failed_message(%{reason: :boom, retry: :not_queued}, false) ==
             "Failed to delete event"
  end

  describe "create_failure_reason/1" do
    test "names Outlook's repeat refusals" do
      assert CalendarEditMessages.create_failure_reason(:rule_not_supported_by_outlook) ==
               "This repeat pattern can't be saved to Outlook."

      assert CalendarEditMessages.create_failure_reason(:day_missing_in_some_months) =~
               "start the series on the 28th or earlier"
    end

    test "asks for another try otherwise" do
      assert CalendarEditMessages.create_failure_reason(:forbidden) == "Please try again."
    end
  end

  describe "video_changed_message/1" do
    test "says the room was created when the event has a link" do
      assert CalendarEditMessages.video_changed_message("https://v.example.com/r") ==
               "Video room created."
    end

    test "says the link was removed when it has none" do
      assert CalendarEditMessages.video_changed_message(nil) == "Video link removed."
    end
  end
end
