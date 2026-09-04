defmodule Tymeslot.Meetings.CalendarEventLinkTest do
  @moduledoc """
  Covers the identity rule matching a meeting to its mirrored provider
  calendar event, which differs by provider family: Google and Outlook agree
  on `provider_event_id`, while a CalDAV meeting holds only a UID and its
  cached copy holds an href.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Meetings.CalendarEventLink

  describe "identifiers/1" do
    test "returns both identifiers when both are present" do
      record = %{provider_event_id: "evt-1", uid: "evt-1@google.com"}

      assert CalendarEventLink.identifiers(record) == ["evt-1", "evt-1@google.com"]
    end

    test "drops nil and whitespace-only values" do
      assert CalendarEventLink.identifiers(%{provider_event_id: nil, uid: "abc@tymeslot.com"}) ==
               ["abc@tymeslot.com"]

      assert CalendarEventLink.identifiers(%{provider_event_id: "  ", uid: nil}) == []
    end

    test "tolerates a record carrying only one of the two fields" do
      assert CalendarEventLink.identifiers(%{uid: "abc@tymeslot.com"}) == ["abc@tymeslot.com"]
    end
  end

  describe "blank_identifier?/1" do
    test "treats nil and whitespace-only values as blank" do
      assert CalendarEventLink.blank_identifier?(nil)
      assert CalendarEventLink.blank_identifier?("")
      assert CalendarEventLink.blank_identifier?("   ")
    end

    test "treats a real identifier as usable" do
      refute CalendarEventLink.blank_identifier?("evt-1")
      refute CalendarEventLink.blank_identifier?("/calendars/x/abc.ics")
    end
  end

  describe "linked?/2" do
    test "matches a CalDAV meeting to a cache row sharing only its UID" do
      meeting = %{provider_event_id: nil, uid: "abc@tymeslot.com"}

      cached = %{
        provider_event_id: "/calendars/sander/default/abc@tymeslot.com.ics",
        uid: "abc@tymeslot.com"
      }

      assert CalendarEventLink.linked?(meeting, CalendarEventLink.identifier_set([cached]))
    end

    test "matches a Google meeting to a cache row sharing only its provider event id" do
      meeting = %{provider_event_id: "evt-1", uid: "tymeslot-generated@tymeslot.com"}
      cached = %{provider_event_id: "evt-1", uid: "evt-1@google.com"}

      assert CalendarEventLink.linked?(meeting, CalendarEventLink.identifier_set([cached]))
    end

    test "does not match records sharing no identifier" do
      meeting = %{provider_event_id: nil, uid: "abc@tymeslot.com"}
      cached = %{provider_event_id: "/calendars/x/other.ics", uid: "other@example.com"}

      refute CalendarEventLink.linked?(meeting, CalendarEventLink.identifier_set([cached]))
    end

    test "a record with no identifiers matches nothing" do
      cached = %{provider_event_id: "evt-1", uid: "evt-1@google.com"}

      refute CalendarEventLink.linked?(
               %{provider_event_id: nil, uid: nil},
               CalendarEventLink.identifier_set([cached])
             )
    end

    test "an empty set matches nothing" do
      refute CalendarEventLink.linked?(
               %{provider_event_id: "evt-1", uid: "evt-1@google.com"},
               CalendarEventLink.identifier_set([])
             )
    end
  end
end
