defmodule TymeslotWeb.Dashboard.CalendarEventHandlersUpdateTest do
  @moduledoc """
  What the calendar tells the organiser when an event's update fails: a
  refusal the domain made names its own reason; anything else is a provider
  failure the organiser can only try again. Off the calendar page nothing is
  handed to a surface, so the flash is what is observed.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Phoenix.Flash
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Dashboard.CalendarEventHandlers

  @refusals [
    {:day_missing_in_some_months,
     "Outlook can't skip the months that don't have this series' day, and would move those events to the month's last day. Please start the series on the 28th or earlier, or save it to another calendar."},
    {:rule_not_supported_by_outlook, "This repeat pattern can't be saved to Outlook."},
    {:not_organiser,
     "Someone else organises this meeting, so Tymeslot can't move or split a series you were only invited to."},
    {:unaddressable_occurrence,
     "This event could not be matched to its series. Refresh your calendars and try again."},
    {:unreadable_timing,
     "This event could not be matched to its series. Refresh your calendars and try again."},
    {:not_recurring,
     "This event could not be matched to its series. Refresh your calendars and try again."},
    {:provider_down, "Failed to update event - changes reverted"}
  ]

  for {reason, message} <- @refusals do
    test "a failure for #{inspect(reason)} says so in its own words" do
      assert flash_for(unquote(reason)) == unquote(message)
    end
  end

  test "a write queued for the next sync keeps the edit and warns once" do
    socket = %Socket{assigns: %{flash: %{}, __changed__: %{}, live_action: :overview}}

    assert {:noreply, updated} =
             CalendarEventHandlers.handle_event_update_result(
               {:error, [write: {"uid", 1}, retry: :queued, reason: :timeout]},
               socket
             )

    assert Flash.get(updated.assigns.flash, :warning) ==
             "Your calendar could not be reached. The change is saved and will sync on the next attempt."

    assert Flash.get(updated.assigns.flash, :error) == nil
  end

  defp flash_for(reason) do
    socket = %Socket{assigns: %{flash: %{}, __changed__: %{}, live_action: :overview}}

    assert {:noreply, updated} =
             CalendarEventHandlers.handle_event_update_result(
               {:error, [original_event: %{id: 1}, reason: reason]},
               socket
             )

    Flash.get(updated.assigns.flash, :error)
  end
end
