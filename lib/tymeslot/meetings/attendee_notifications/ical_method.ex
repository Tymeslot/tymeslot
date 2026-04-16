defmodule Tymeslot.Meetings.AttendeeNotifications.IcalMethod do
  @moduledoc """
  Single source of truth for the iCalendar METHOD and SEQUENCE used for each
  attendee-notification action. See the design spec for the full table.
  """

  @type action ::
          :event_created
          | :event_updated
          | :attendees_added
          | :attendees_removed
          | :event_deleted
  @type method :: :request | :cancel

  @spec for(action, current_sequence: non_neg_integer) :: {method, non_neg_integer}
  def for(:event_created, current_sequence: _n), do: {:request, 0}
  def for(:event_updated, current_sequence: n), do: {:request, n + 1}
  def for(:attendees_added, current_sequence: n), do: {:request, n}
  def for(:attendees_removed, current_sequence: n), do: {:cancel, n}
  def for(:event_deleted, current_sequence: n), do: {:cancel, n + 1}
end
