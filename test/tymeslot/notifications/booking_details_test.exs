defmodule Tymeslot.Notifications.BookingDetailsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :notifications
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.BookingDetails

  @snapshot [
    %{"id" => "q1", "type" => "text", "label" => "What should we cover?"},
    %{"id" => "q2", "type" => "yes_no", "label" => "First call?"},
    %{"id" => "q3", "type" => "text", "label" => "Left blank"}
  ]

  @meeting %{
    attendee_message: "  Please call me first.  ",
    attendee_phone: "+44 20 7946 0000",
    attendee_company: "Acme Ltd",
    location: "1 High Street, Oxford",
    location_kind: :in_person,
    custom_fields_snapshot: @snapshot,
    custom_field_answers: %{"q1" => "Pricing", "q2" => true, "q3" => ""}
  }

  describe "from_meeting/1" do
    test "carries the booker's notes, contact details, location and answered questions" do
      assert BookingDetails.from_meeting(@meeting) == %{
               note: "Please call me first.",
               phone: "+44 20 7946 0000",
               company: "Acme Ltd",
               location: "1 High Street, Oxford",
               answers: [{"What should we cover?", "Pricing"}, {"First call?", "Yes"}],
               more_answers: 0
             }
    end

    test "leaves out a video meeting's location, which is its room link" do
      meeting = %{@meeting | location: "https://meet.example.com/room", location_kind: :video}

      assert BookingDetails.from_meeting(meeting).location == nil
    end

    test "leaves out the phone number a phone meeting is already held on" do
      meeting = %{@meeting | location: "+44 20 7946 0000", location_kind: :phone}

      details = BookingDetails.from_meeting(meeting)

      assert details.location == "+44 20 7946 0000"
      assert details.phone == nil
    end

    test "reads blank and missing fields as absent" do
      details =
        BookingDetails.from_meeting(%{attendee_message: " ", attendee_phone: nil, location: nil})

      assert details == %{
               note: nil,
               phone: nil,
               company: nil,
               location: nil,
               answers: [],
               more_answers: 0
             }
    end

    test "cuts long notes and answers, and counts the answers past the cap" do
      snapshot =
        for n <- 1..12, do: %{"id" => "q#{n}", "type" => "text", "label" => "Question #{n}"}

      answers = Map.new(1..12, &{"q#{&1}", String.duplicate("a", 400)})

      details =
        BookingDetails.from_meeting(%{
          attendee_message: String.duplicate("n", 2_000),
          custom_fields_snapshot: snapshot,
          custom_field_answers: answers
        })

      assert String.length(details.note) == 501
      assert length(details.answers) == 10
      assert details.more_answers == 2
      assert Enum.reject(details.answers, fn {_l, v} -> String.length(v) == 151 end) == []
    end

    test "for a group seat, reads that participant's notes and answers, not the meeting row's" do
      meeting =
        insert(:group_meeting,
          attendee_message: "row notes",
          custom_fields_snapshot: @snapshot,
          custom_field_answers: %{"q1" => "row answer"}
        )

      participant =
        insert(:participant,
          meeting: meeting,
          message: "seat notes",
          phone: "+1 555 0100",
          custom_field_answers: %{"q1" => "seat answer"}
        )

      details = BookingDetails.from_meeting(SeatView.at_event(meeting, participant, 1))

      assert details.note == "seat notes"
      assert details.phone == "+1 555 0100"
      assert details.answers == [{"What should we cover?", "seat answer"}, {"First call?", "No"}]
    end
  end
end
