defmodule TymeslotWeb.Dashboard.CalendarEditMessagesTest do
  @moduledoc "The copy both calendars show when a change is refused or fails."

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
end
