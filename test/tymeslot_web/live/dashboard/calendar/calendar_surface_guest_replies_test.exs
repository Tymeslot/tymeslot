defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceGuestRepliesTest do
  @moduledoc """
  How each guest has answered, in the preview and the side panel, on a
  desktop and on a phone: a calendar event's attendees with the reply their
  calendar reported, a booking's invited guests with the answer they gave
  on the RSVP page, and an answer given while the preview is open reaching
  it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests

  setup %{conn: conn}, do: owner(conn)

  @attendees [
    %{
      "email" => "ada@example.com",
      "display_name" => "Ada Lovelace",
      "response_status" => "accepted"
    },
    %{
      "email" => "grace@example.com",
      "display_name" => "Grace Hopper",
      "response_status" => "declined"
    },
    %{
      "email" => "alan@example.com",
      "display_name" => "Alan Turing",
      "response_status" => "tentative"
    },
    %{
      "email" => "kathy@example.com",
      "display_name" => "Kathy Sierra",
      "response_status" => "needs_action"
    },
    %{"email" => "linus@example.com", "display_name" => "Linus Pauling"}
  ]

  defp hook(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp review(integration),
    do:
      event(integration, "work", "Design review", ~U[2026-10-14 13:00:00Z], 60,
        attendees: @attendees
      )

  test "the preview shows each guest's answer, and how many are going", %{
    conn: conn,
    integration: integration
  } do
    review = review(integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:open", %{"id" => "event-#{review.id}"})

    assert has_element?(lv, "#calendar-preview-guests li", ~r/Ada Lovelace\s+Going/)
    assert has_element?(lv, "#calendar-preview-guests li", ~r/Grace Hopper\s+Declined/)
    assert has_element?(lv, "#calendar-preview-guests li", ~r/Alan Turing\s+Maybe/)
    assert has_element?(lv, "#calendar-preview-guests li", ~r/Kathy Sierra\s+Awaiting reply/)
    # Its calendar reported no reply: nothing is claimed for it.
    assert has_element?(lv, "#calendar-preview-guests li", ~r/\A\s*Linus Pauling\s*\z/)
    assert has_element?(lv, "#calendar-preview-guest-summary", "1 of 4 guests going, 1 declined")
  end

  test "with no answer reported the preview lists the guests and counts nothing", %{
    conn: conn,
    integration: integration
  } do
    quiet =
      event(integration, "work", "Catch-up", ~U[2026-10-14 15:00:00Z], 30,
        attendees: [%{"email" => "ada@example.com", "display_name" => "Ada Lovelace"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:open", %{"id" => "event-#{quiet.id}"})

    assert has_element?(lv, "#calendar-preview-guests li", "Ada Lovelace")
    refute has_element?(lv, "#calendar-preview-guest-summary")
  end

  test "a booking lists its invited guests, and an answer given meanwhile reaches the open preview",
       %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user: user,
        title: "Intro call with Anna Kowalski",
        attendee_name: "Anna Kowalski",
        attendee_email: "anna@example.com",
        start_time: ~U[2026-10-14 13:00:00Z],
        end_time: ~U[2026-10-14 13:30:00Z],
        status: "confirmed"
      )

    {:ok, [guest]} = Guests.create_for_meeting(meeting.id, ["grace@example.com"], :organizer)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:open", %{"id" => "booking-#{meeting.id}"})

    assert has_element?(lv, "#calendar-preview-guests li", ~r/\A\s*Anna Kowalski\s*\z/)

    assert has_element?(
             lv,
             "#calendar-preview-guests li",
             ~r/grace@example\.com\s+Awaiting reply/
           )

    {:ok, _guest} = Meetings.record_guest_rsvp(guest.rsvp_token, :accepted)

    assert_push_event(lv, "calendar:events", %{reset: true})
    assert has_element?(lv, "#calendar-preview-guests li", ~r/grace@example\.com\s+Going/)
    assert has_element?(lv, "#calendar-preview-guest-summary", "1 of 1 guests going")
  end

  test "the side panel's guest rows show each answer beside the remove button", %{
    conn: conn,
    integration: integration
  } do
    review = review(integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    hook(lv, "calendar:edit", %{"id" => "event-#{review.id}"})

    assert has_element?(lv, "#calendar-panel-guests li", ~r/Ada Lovelace\s+Going/)
    assert has_element?(lv, "#calendar-panel-guests li", ~r/Alan Turing\s+Maybe/)
    assert has_element?(lv, "#calendar-panel-guests li", ~r/\A\s*Linus Pauling\s*\z/)

    assert has_element?(
             lv,
             ~s|#calendar-panel-guests li button[phx-value-email="ada@example.com"]|
           )
  end

  describe "on a phone" do
    setup %{conn: conn}, do: %{conn: put_connect_params(conn, %{"viewport" => "phone"})}

    test "the preview sheet shows the same answers", %{conn: conn, integration: integration} do
      review = review(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      hook(lv, "calendar:open", %{"id" => "event-#{review.id}"})

      assert has_element?(lv, "#calendar-preview-guests li", ~r/Kathy Sierra\s+Awaiting reply/)

      assert has_element?(
               lv,
               "#calendar-preview-guests li span[class~='truncate']",
               "Kathy Sierra"
             )
    end

    test "the panel sheet's guest rows are tall enough for a thumb", %{
      conn: conn,
      integration: integration
    } do
      review = review(integration)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      hook(lv, "calendar:edit", %{"id" => "event-#{review.id}"})

      assert has_element?(lv, "#calendar-panel-guests li[class~='min-h-11']", "Ada Lovelace")
    end
  end
end
