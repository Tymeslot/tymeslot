defmodule Tymeslot.Integrations.Video.EventDetailsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video.EventDetails

  describe "from_creating_form/1" do
    test "builds a struct from a creating map with all fields" do
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600, :second)

      creating = %{
        title: "Team Standup",
        description: "Daily sync",
        start_time: now,
        end_time: later,
        attendees: ["alice@example.com", "bob@example.com"]
      }

      details = EventDetails.from_creating_form(creating)

      assert details.summary == "Team Standup"
      assert details.description == "Daily sync"
      assert details.start_time == now
      assert details.end_time == later

      assert details.attendees == [
               %{email: "alice@example.com", name: nil},
               %{email: "bob@example.com", name: nil}
             ]
    end

    test "normalises bare-string attendees to %{email: _, name: nil} with email trimmed and downcased" do
      creating = %{title: "Call", attendees: ["  Alice@Example.COM  "]}

      details = EventDetails.from_creating_form(creating)

      assert details.attendees == [%{email: "alice@example.com", name: nil}]
    end

    test "normalises empty title to nil" do
      details = EventDetails.from_creating_form(%{title: ""})

      assert details.summary == nil
    end

    test "normalises whitespace-only title to nil" do
      details = EventDetails.from_creating_form(%{title: "   "})

      assert details.summary == nil
    end

    test "defaults description to empty string when missing" do
      details = EventDetails.from_creating_form(%{title: "Call"})

      assert details.description == ""
    end

    test "yields empty attendees list when attendees key is absent" do
      details = EventDetails.from_creating_form(%{title: "Call"})

      assert details.attendees == []
    end

    test "yields empty attendees list when attendees list is empty" do
      details = EventDetails.from_creating_form(%{title: "Call", attendees: []})

      assert details.attendees == []
    end
  end

  describe "from_grid_event/1" do
    test "builds a struct from an atom-keyed event map" do
      now = DateTime.utc_now()
      later = DateTime.add(now, 3600, :second)

      event = %{
        summary: "Planning",
        description: "Quarterly plan",
        start_at: now,
        end_at: later,
        attendees: [%{email: "carol@example.com", name: "Carol"}]
      }

      details = EventDetails.from_grid_event(event)

      assert details.summary == "Planning"
      assert details.description == "Quarterly plan"
      assert details.start_time == now
      assert details.end_time == later
      assert details.attendees == [%{email: "carol@example.com", name: "Carol"}]
    end

    test "accepts string-key attendee maps and normalises them" do
      event = %{
        summary: "Meeting",
        attendees: [%{"email" => "Dave@Example.COM", "name" => "Dave"}]
      }

      details = EventDetails.from_grid_event(event)

      assert details.attendees == [%{email: "dave@example.com", name: "Dave"}]
    end

    test "accepts atom-key attendee maps and normalises email" do
      event = %{
        summary: "Meeting",
        attendees: [%{email: "  Eve@Example.COM  ", name: "Eve"}]
      }

      details = EventDetails.from_grid_event(event)

      assert details.attendees == [%{email: "eve@example.com", name: "Eve"}]
    end

    test "normalises mixed list of bare strings and maps consistently" do
      event = %{
        summary: "Mixed",
        attendees: [
          "frank@example.com",
          %{"email" => "Grace@Example.COM", "name" => "Grace"},
          %{email: "henry@example.com", name: "Henry"}
        ]
      }

      details = EventDetails.from_grid_event(event)

      assert details.attendees == [
               %{email: "frank@example.com", name: nil},
               %{email: "grace@example.com", name: "Grace"},
               %{email: "henry@example.com", name: "Henry"}
             ]
    end

    test "yields empty attendees list when attendees key is absent" do
      details = EventDetails.from_grid_event(%{summary: "Meeting"})

      assert details.attendees == []
    end

    test "rejects attendee entries with missing or empty email" do
      event = %{
        summary: "Meeting",
        attendees: [
          %{email: "", name: "No Email"},
          %{"email" => "", "name" => "Also No Email"},
          "valid@example.com"
        ]
      }

      details = EventDetails.from_grid_event(event)

      assert details.attendees == [%{email: "valid@example.com", name: nil}]
    end

    test "normalises empty summary to nil" do
      details = EventDetails.from_grid_event(%{summary: ""})

      assert details.summary == nil
    end

    test "defaults description to empty string when missing" do
      details = EventDetails.from_grid_event(%{summary: "Meeting"})

      assert details.description == ""
    end
  end

  describe "from_meeting/1" do
    test "carries the meeting's summary, times, description, and attendee" do
      meeting =
        build(:meeting,
          summary: "Discovery Call",
          description: "First conversation",
          attendee_email: "alice@example.com",
          attendee_name: "Alice"
        )

      details = EventDetails.from_meeting(meeting)

      assert details.summary == "Discovery Call"
      assert details.description == "First conversation"
      assert details.start_time == meeting.start_time
      assert details.end_time == meeting.end_time
      assert details.attendees == [%{email: "alice@example.com", name: "Alice"}]
    end

    test "falls back to title when summary is nil and defaults description to empty string" do
      meeting = build(:meeting, summary: nil, title: "Onboarding Sync", description: nil)

      details = EventDetails.from_meeting(meeting)

      assert details.summary == "Onboarding Sync"
      assert details.description == ""
    end

    test "omits attendee entry when attendee_email is missing" do
      meeting = build(:meeting, attendee_email: nil)

      details = EventDetails.from_meeting(meeting)

      assert details.attendees == []
    end

    test "downcases and trims attendee email" do
      meeting =
        build(:meeting,
          attendee_email: "  Alice@Example.COM  ",
          attendee_name: "Alice"
        )

      details = EventDetails.from_meeting(meeting)

      assert details.attendees == [%{email: "alice@example.com", name: "Alice"}]
    end
  end
end
