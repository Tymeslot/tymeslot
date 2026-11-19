defmodule TymeslotWeb.Dashboard.CalendarEventHandlersAdHocTest do
  @moduledoc """
  What the organiser is told when a meeting they created from the calendar
  (a Tymeslot meeting with guests, `EventCreation.run_create_ad_hoc_meeting/1`)
  has been made or refused, and that the calendar hears of it only while it
  is on screen.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :calendar
  @moduletag :meetings

  alias Phoenix.Flash
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Dashboard.CalendarEventHandlers

  defp off_calendar,
    do: %Socket{assigns: %{flash: %{}, __changed__: %{}, live_action: :overview}}

  test "a created meeting is confirmed, and off the calendar page no calendar is updated" do
    assert {:noreply, updated} =
             CalendarEventHandlers.handle_create_ad_hoc_meeting_result(
               make_ref(),
               {:ok, %{}},
               off_calendar()
             )

    assert Flash.get(updated.assigns.flash, :info) == "Meeting created and invitation sent"
    refute_received {:phoenix, :send_update, _update}
  end

  test "a clash is refused without naming a meeting the host may not see" do
    assert {:noreply, updated} =
             CalendarEventHandlers.handle_create_ad_hoc_meeting_result(
               make_ref(),
               {:error, :time_conflict},
               off_calendar()
             )

    assert Flash.get(updated.assigns.flash, :error) ==
             "This time is no longer available. Please choose another time."
  end

  test "a reason the calendar has no words for never reaches the flash verbatim" do
    assert {:noreply, updated} =
             CalendarEventHandlers.handle_create_ad_hoc_meeting_result(
               make_ref(),
               {:error, :some_unknown_reason},
               off_calendar()
             )

    message = Flash.get(updated.assigns.flash, :error)
    assert is_binary(message) and message != ""
    refute message =~ "some_unknown_reason"
  end

  test "a create that raises still answers, with a generic failure for the organiser" do
    # Every field `CreateAdHoc` reads is missing, so the create raises.
    request = make_ref()

    log =
      capture_log(fn ->
        assert {:noreply, _socket} =
                 CalendarEventHandlers.handle_execute_create_ad_hoc_meeting(
                   request,
                   %{},
                   off_calendar()
                 )

        assert_receive {:create_ad_hoc_meeting_result, ^request, {:error, :crashed}}, 5_000
      end)

    assert log =~ "Calendar grid task crashed"

    assert {:noreply, updated} =
             CalendarEventHandlers.handle_create_ad_hoc_meeting_result(
               make_ref(),
               {:error, :crashed},
               off_calendar()
             )

    assert Flash.get(updated.assigns.flash, :error) ==
             "Failed to create meeting. Please try again."
  end
end
