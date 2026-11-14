defmodule Tymeslot.Slack.MessageBuilderTest do
  use ExUnit.Case, async: true

  @moduletag :slack
  @moduletag :unit

  alias Tymeslot.Notifications.EventTypes
  alias Tymeslot.Slack.MessageBuilder

  @meeting %{
    attendee_name: "John Smith",
    attendee_email: "john@example.com",
    attendee_timezone: "America/New_York",
    start_time: ~U[2026-03-10 14:00:00Z],
    end_time: ~U[2026-03-10 14:30:00Z],
    event_type: %{name: "30-minute intro call"},
    id: "6f1d2c3b-0a4e-4b8f-9c7d-1e2f3a4b5c6d",
    uid: "abc123",
    cancellation_reason: nil
  }

  # The organiser's timezone, deliberately different from the attendee's: these
  # messages land in the organiser's channel, so every time below is theirs.
  @timezone "UTC"

  describe "build_blocks/3 for every subscribable event" do
    test "each one has a dedicated header rather than the generic fallback" do
      meeting = Map.merge(@meeting, %{approval_deadline_at: nil, decline_reason: nil})

      assert EventTypes.all() != []

      generic =
        Enum.filter(EventTypes.all(), fn event ->
          [%{"text" => %{"text" => header}} | _rest] =
            MessageBuilder.build_blocks(event, meeting, @timezone)

          header == "Meeting update"
        end)

      assert generic == []
    end

    test "an unknown event name still builds the generic blocks" do
      assert [%{"text" => %{"text" => "Meeting update"}} | _rest] =
               MessageBuilder.build_blocks("meeting.renamed", @meeting, @timezone)
    end
  end

  describe "build_blocks/3 — meeting.created" do
    test "includes a header block, summary, details, and an action button" do
      blocks = MessageBuilder.build_blocks("meeting.created", @meeting, @timezone)

      assert [
               %{"type" => "header", "text" => %{"text" => "New booking"}},
               %{"type" => "section"},
               %{"type" => "divider"},
               %{"type" => "section"},
               %{"type" => "actions"}
             ] = Enum.map(blocks, &Map.take(&1, ["type", "text"]))

      json = Jason.encode!(blocks)
      assert json =~ "John Smith"
      assert json =~ "john@example.com"
      assert json =~ "14:00"
      assert json =~ "14:30"
      assert json =~ "Open in Tymeslot"
      assert json =~ "Meeting"
    end
  end

  describe "build_blocks/3 — a meeting the host manages" do
    # Without a main participant, its first guest fills the attendee fields
    # under their address for a name; the host arranged it, nobody booked it.
    @managed Map.merge(@meeting, %{
               managed_by_host: true,
               attendee_name: "guest@example.com",
               attendee_email: "guest@example.com"
             })

    test "is announced as a new meeting, not a booking, naming the guest's address once" do
      [header, %{"text" => %{"text" => summary}} | _rest] =
        MessageBuilder.build_blocks("meeting.created", @managed, @timezone)

      assert header["text"]["text"] == "New meeting"
      assert summary =~ ~r/\nWith guest@example\.com$/
    end

    test "a poll-confirmed one keeps its guest's name beside the address" do
      meeting = Map.put(@managed, :attendee_name, "Ada Lovelace")

      [_header, %{"text" => %{"text" => summary}} | _rest] =
        MessageBuilder.build_blocks("meeting.created", meeting, @timezone)

      assert summary =~ "With Ada Lovelace (guest@example.com)"
    end
  end

  describe "build_blocks/3 — meeting.cancelled" do
    test "includes the cancellation reason in a quote block" do
      meeting = %{@meeting | cancellation_reason: "Schedule conflict"}
      blocks = MessageBuilder.build_blocks("meeting.cancelled", meeting, @timezone)
      json = Jason.encode!(blocks)
      assert json =~ "Booking cancelled"
      assert json =~ "Schedule conflict"
      assert json =~ ">Schedule conflict"
    end

    test "falls back to 'No reason given' when cancellation_reason is missing" do
      blocks = MessageBuilder.build_blocks("meeting.cancelled", @meeting, @timezone)
      assert Jason.encode!(blocks) =~ "No reason given"
    end

    test "truncates cancellation reasons longer than 500 chars with ellipsis" do
      long_reason = String.duplicate("a", 600)
      meeting = %{@meeting | cancellation_reason: long_reason}
      blocks = MessageBuilder.build_blocks("meeting.cancelled", meeting, @timezone)
      json = Jason.encode!(blocks)
      assert json =~ "aaa..."
      refute String.contains?(json, String.duplicate("a", 600))
    end
  end

  describe "build_blocks/3 — meeting.rescheduled" do
    test "includes the new time and an action button" do
      blocks = MessageBuilder.build_blocks("meeting.rescheduled", @meeting, @timezone)
      json = Jason.encode!(blocks)
      assert json =~ "Booking rescheduled"
      assert json =~ "New time"
      assert json =~ "14:00"
      assert json =~ "Open in Tymeslot"
    end
  end

  describe "build_blocks/3 — meeting.requested" do
    test "includes the deadline and an action button" do
      meeting = Map.put(@meeting, :approval_deadline_at, ~U[2026-03-12 14:00:00Z])
      blocks = MessageBuilder.build_blocks("meeting.requested", meeting, @timezone)

      assert [
               %{"type" => "header", "text" => %{"text" => "New booking request"}},
               %{"type" => "section"},
               %{"type" => "divider"},
               %{"type" => "section"},
               %{"type" => "actions"}
             ] = Enum.map(blocks, &Map.take(&1, ["type", "text"]))

      json = Jason.encode!(blocks)
      assert json =~ "John Smith"
      assert json =~ "Respond by"
      assert json =~ "12 Mar 2026"
      assert json =~ "Open in Tymeslot"
      refute json =~ "Meeting update"
    end

    test "omits the deadline field when the request has no deadline" do
      meeting = Map.put(@meeting, :approval_deadline_at, nil)
      blocks = MessageBuilder.build_blocks("meeting.requested", meeting, @timezone)
      refute Jason.encode!(blocks) =~ "Respond by"
    end
  end

  describe "build_blocks/3 — meeting.declined" do
    test "includes the host's decline reason in a quote block" do
      meeting = Map.put(@meeting, :decline_reason, "Not available that day")
      blocks = MessageBuilder.build_blocks("meeting.declined", meeting, @timezone)

      assert [
               %{"type" => "header", "text" => %{"text" => "Booking request declined"}},
               %{"type" => "section"},
               %{"type" => "divider"},
               %{"type" => "section"}
             ] = Enum.map(blocks, &Map.take(&1, ["type", "text"]))

      json = Jason.encode!(blocks)
      assert json =~ "Not available that day"
      assert json =~ ">Not available that day"
      refute json =~ "Meeting update"
    end

    test "falls back to 'No reason given' when decline_reason is missing" do
      meeting = Map.put(@meeting, :decline_reason, nil)
      blocks = MessageBuilder.build_blocks("meeting.declined", meeting, @timezone)
      assert Jason.encode!(blocks) =~ "No reason given"
    end

    test "truncates decline reasons longer than 500 chars with ellipsis" do
      long_reason = String.duplicate("a", 600)
      meeting = Map.put(@meeting, :decline_reason, long_reason)
      blocks = MessageBuilder.build_blocks("meeting.declined", meeting, @timezone)
      json = Jason.encode!(blocks)
      assert json =~ "aaa..."
      refute String.contains?(json, String.duplicate("a", 600))
    end
  end

  describe "build_blocks/3 — meeting.request_expired" do
    test "explains that nobody responded before the deadline" do
      blocks = MessageBuilder.build_blocks("meeting.request_expired", @meeting, @timezone)

      assert [
               %{"type" => "header", "text" => %{"text" => "Booking request expired"}},
               %{"type" => "section"},
               %{"type" => "divider"},
               %{"type" => "section"}
             ] = Enum.map(blocks, &Map.take(&1, ["type", "text"]))

      json = Jason.encode!(blocks)
      assert json =~ "Nobody responded"
      assert json =~ "John Smith"
      refute json =~ "Meeting update"
    end
  end

  describe "build_blocks/3 — timezone" do
    test "renders times in the organiser's timezone, not the attendee's" do
      blocks = MessageBuilder.build_blocks("meeting.created", @meeting, "Europe/Tallinn")
      json = Jason.encode!(blocks)
      assert json =~ "16:00"
      assert json =~ "Europe/Tallinn"
      refute json =~ "America/New_York"
    end

    test "renders the approval deadline in the organiser's timezone" do
      meeting = Map.put(@meeting, :approval_deadline_at, ~U[2026-03-12 14:00:00Z])
      blocks = MessageBuilder.build_blocks("meeting.requested", meeting, "Europe/Tallinn")
      json = Jason.encode!(blocks)
      assert json =~ "12 Mar 2026, 16:00 (Europe/Tallinn)"
    end

    test "labels times UTC, not the failed zone, when the organiser's zone is unknown" do
      meeting = Map.put(@meeting, :approval_deadline_at, ~U[2026-03-12 14:00:00Z])
      blocks = MessageBuilder.build_blocks("meeting.requested", meeting, "Mars/Olympus_Mons")
      json = Jason.encode!(blocks)

      assert json =~ "Tue 10 Mar 2026, 14:00–14:30 (UTC)"
      assert json =~ "12 Mar 2026, 14:00 (UTC)"
      refute json =~ "Mars/Olympus_Mons"
    end
  end

  describe "build_blocks/3: what the booker told the organiser" do
    @details %{
      attendee_message: "Bring the <Q3> figures\n& slides",
      attendee_phone: "+44 20 7946 0000",
      attendee_company: "Acme Ltd",
      location: "1 High Street, Oxford",
      location_kind: :in_person,
      custom_fields_snapshot: [%{"id" => "q1", "type" => "text", "label" => "Topic"}],
      custom_field_answers: %{"q1" => "Pricing <now>"},
      approval_deadline_at: nil
    }

    for event <- [:meeting_created, :meeting_rescheduled, :meeting_requested] do
      test "#{event} shows the notes, contact details, location and answers, escaped" do
        texts =
          EventTypes.to_event_type(unquote(event))
          |> MessageBuilder.build_blocks(Map.merge(@meeting, @details), @timezone)
          |> block_texts()

        assert "*Notes*\n>Bring the &lt;Q3&gt; figures\n>&amp; slides" in texts
        assert "*Where*\n1 High Street, Oxford" in texts
        assert "*Phone*\n+44 20 7946 0000" in texts
        assert "*Company*\nAcme Ltd" in texts
        assert "*Topic*\nPricing &lt;now&gt;" in texts
      end
    end

    test "a cancellation leaves them out" do
      json =
        "meeting.cancelled"
        |> MessageBuilder.build_blocks(Map.merge(@meeting, @details), @timezone)
        |> Jason.encode!()

      refute json =~ "figures"
      refute json =~ "Topic"
    end

    test "counts the answers past the cap in a context line" do
      snapshot = for n <- 1..12, do: %{"id" => "q#{n}", "type" => "text", "label" => "Q#{n}"}

      meeting =
        Map.merge(@meeting, %{
          custom_fields_snapshot: snapshot,
          custom_field_answers: Map.new(1..12, &{"q#{&1}", "answer"})
        })

      texts =
        "meeting.created"
        |> MessageBuilder.build_blocks(meeting, @timezone)
        |> block_texts()

      assert "*Q10*\nanswer" in texts
      refute "*Q11*\nanswer" in texts
      assert "2 more answers in Tymeslot" in texts
    end

    # Every mrkdwn string in the blocks, whether a section's text, one of its
    # fields, or a context element.
    defp block_texts(blocks) do
      for block <- blocks,
          %{"type" => "mrkdwn", "text" => text} <-
            [block["text"] | (block["fields"] || []) ++ (block["elements"] || [])],
          do: text
    end
  end

  describe "escaping" do
    test "escapes Slack mrkdwn special characters in attendee_name" do
      meeting = %{@meeting | attendee_name: "<script>alert('xss')</script>"}
      blocks = MessageBuilder.build_blocks("meeting.created", meeting, @timezone)
      json = Jason.encode!(blocks)
      refute json =~ "<script>"
      assert json =~ "&lt;script&gt;"
    end

    test "falls back to attendee_email when attendee_name is nil" do
      meeting = %{@meeting | attendee_name: nil}
      blocks = MessageBuilder.build_blocks("meeting.created", meeting, @timezone)
      assert Jason.encode!(blocks) =~ "john@example.com"
    end
  end

  # The uid is the booker's capability (the cancel and reschedule links are
  # built from it), so the host's link names the booking by its id.
  describe "build_blocks/3: the link to the booking" do
    test "names the booking by its id, never its uid" do
      out = Jason.encode!(MessageBuilder.build_blocks("meeting.created", @meeting, @timezone))

      assert out =~ "/dashboard/meetings?meeting=#{@meeting.id}"
      refute out =~ @meeting.uid
    end
  end

  describe "build_test_blocks/0" do
    test "returns a header + section block referencing Tymeslot" do
      blocks = MessageBuilder.build_test_blocks()
      json = Jason.encode!(blocks)
      assert json =~ "Tymeslot test message"
      assert json =~ "configured correctly"
    end
  end

  test "a meeting ending the next day shows the end with its own day" do
    meeting = %{
      @meeting
      | start_time: ~U[2026-03-10 23:30:00Z],
        end_time: ~U[2026-03-11 00:30:00Z]
    }

    json = "meeting.created" |> MessageBuilder.build_blocks(meeting, @timezone) |> Jason.encode!()

    assert json =~ "Tue 10 Mar 2026, 23:30 – Wed 11 Mar 00:30"
  end
end
