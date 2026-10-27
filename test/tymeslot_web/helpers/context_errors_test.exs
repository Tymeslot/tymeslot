defmodule TymeslotWeb.Helpers.ContextErrorsTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.ContextErrors

  describe "format_context_error/1" do
    test "explains a calendar gone while the save ran, rather than naming the atom" do
      assert %{base: [message]} = ContextErrors.format_context_error(:not_found)
      assert message =~ "no longer available"
    end

    test "formats known error atoms" do
      assert ContextErrors.format_context_error(:video_integration_required) ==
               %{video_integration: ["Please select a video provider for video meetings"]}

      assert ContextErrors.format_context_error(:invalid_duration) ==
               %{duration: ["Duration must be a valid number"]}
    end

    test "formats target calendar errors" do
      assert ContextErrors.format_context_error(:target_calendar_required) ==
               %{target_calendar: ["Please select a target calendar"]}

      assert ContextErrors.format_context_error(:target_calendar_invalid) ==
               %{target_calendar: ["Selected calendar is not available for this account"]}
    end

    test "formats no_writable_calendars with an explanation and a way forward" do
      assert %{target_calendar: [message]} =
               ContextErrors.format_context_error(:no_writable_calendars)

      assert message =~ "None of the calendars you selected for this account can accept bookings"
    end

    test "formats invalid approval window against its own field, not base" do
      assert ContextErrors.format_context_error(:invalid_approval_window) ==
               %{
                 approval_window_hours: [
                   "Enter a whole number of hours, or leave blank to use the default."
                 ]
               }
    end

    test "formats generic atoms to capitalized base error" do
      assert ContextErrors.format_context_error(:something_went_wrong) ==
               %{base: ["Something went wrong"]}
    end

    test "formats non-atom errors to string base error" do
      assert ContextErrors.format_context_error("string error") ==
               %{base: ["string error"]}
    end
  end

  describe "format_context_error/1 for a venue that is not the host's" do
    test "explains it in words rather than as a humanised atom" do
      assert %{base: ["A selected location is not one of yours"]} =
               ContextErrors.format_context_error(:invalid_venue)
    end
  end
end
