defmodule Tymeslot.CalendarGrid.GuestRepliesTest do
  @moduledoc """
  Who an event on the calendar is with and how each has answered: a
  calendar event's attendees with the reply their calendar reported, a
  booking's booker (who owes no answer) and its invited guests with theirs,
  and the count of those going.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.BookingEvent
  alias Tymeslot.CalendarGrid.GuestReplies

  defp booking(attrs) do
    struct!(
      BookingEvent,
      Map.merge(
        %{
          id: "booking-1",
          meeting_id: "m1",
          summary: "Intro call",
          start_at: ~U[2026-10-15 09:00:00Z],
          end_at: ~U[2026-10-15 09:30:00Z]
        },
        attrs
      )
    )
  end

  test "a calendar event's attendees carry the reply their calendar reported" do
    event = %{
      attendees: [
        %{"email" => "ada@example.com", "display_name" => "Ada", "response_status" => "accepted"},
        %{"email" => "grace@example.com", "response_status" => "needs_action"},
        %{"email" => "alan@example.com", "display_name" => " ", "response_status" => "tentative"},
        %{"email" => "kurt@example.com", "response_status" => "declined"},
        %{"email" => "linus@example.com"}
      ]
    }

    assert GuestReplies.of_event(event) == [
             %{name: "Ada", reply: :accepted},
             %{name: "grace@example.com", reply: :pending},
             %{name: "alan@example.com", reply: :tentative},
             %{name: "kurt@example.com", reply: :declined},
             %{name: "linus@example.com", reply: nil}
           ]
  end

  test "a booking's booker owes no answer; its invited guests carry theirs" do
    one_to_one =
      booking(%{
        attendee_name: "Anna Kowalski",
        attendee_email: "anna@example.com",
        guests: [
          %{name: nil, email: "grace@example.com", status: :pending},
          %{name: "Alan", email: "alan@example.com", status: :declined},
          %{name: nil, email: "kurt@example.com", status: :pending}
        ]
      })

    assert GuestReplies.of_event(one_to_one) == [
             %{name: "Anna Kowalski", reply: nil},
             %{name: "grace@example.com", reply: :pending},
             %{name: "Alan", reply: :declined},
             %{name: "kurt@example.com", reply: :pending}
           ]
  end

  test "a group meeting's people are its participants" do
    group =
      booking(%{
        participants: [
          %{name: "Bo", email: "bo@example.com"},
          %{name: nil, email: "cy@example.com"}
        ]
      })

    assert GuestReplies.of_event(group) == [
             %{name: "Bo", reply: nil},
             %{name: "cy@example.com", reply: nil}
           ]
  end

  test "summary/1 counts those with an answer, and is nil when nobody has one" do
    guests = [
      %{name: "a", reply: :accepted},
      %{name: "b", reply: :declined},
      %{name: "c", reply: :pending},
      %{name: "d", reply: :tentative},
      %{name: "e", reply: nil}
    ]

    assert GuestReplies.summary(guests) == %{total: 4, accepted: 1, declined: 1}
    assert GuestReplies.summary([%{name: "e", reply: nil}]) == nil
  end
end
