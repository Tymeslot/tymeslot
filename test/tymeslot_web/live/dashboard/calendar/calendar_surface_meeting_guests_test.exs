defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMeetingGuestsTest do
  @moduledoc """
  The guests of a "Send as a Tymeslot meeting" draft in the side panel's
  New event state: the box is offered once the draft has a guest, added or
  typed; an address typed but not added survives the form's other changes
  and is invited on Create; and the meeting's own guest limit holds at Add
  and at Create.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.Meetings.Guests

  setup %{conn: conn} do
    context = owner(conn)
    forward_creates(self())
    context
  end

  test "is offered once the draft has a guest, and says what it does", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration, %{"guests" => []})

    refute has_element?(lv, "#calendar-panel-meeting")

    render_submit(new_event_form(lv), %{
      "intent" => "add_guest",
      "guest_email" => "ada@example.com"
    })

    assert has_element?(lv, "#calendar-panel-meeting", "Send as a Tymeslot meeting")

    assert has_element?(
             lv,
             "#calendar-panel-meeting",
             "Books the slot, emails the guest an invitation, and adds it to your calendar."
           )

    refute has_element?(lv, "#calendar-panel-meeting-fields")
  end

  test "is offered for a guest typed but not added yet, who Create then invites", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration, %{"guests" => []})

    render_change(new_event_form(lv), %{"guest_email" => "ada@example.com"})
    assert has_element?(lv, "#calendar-panel-meeting", "Send as a Tymeslot meeting")

    render_change(new_event_form(lv), %{"guest_email" => "ada@example.com", "meeting" => "true"})
    assert has_element?(lv, "#calendar-panel-meeting-guest-name")

    trace_surface(lv)
    book_meeting(lv, %{"guest_email" => "ada@example.com", "meeting" => "true"})

    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}
    assert %{attendee_email: "ada@example.com", guest_emails: []} = params
  end

  # The form's own fields post what the panel drew, as a browser's do once
  # a change elsewhere has re-rendered them: these submit without the
  # address, which only survives if the panel draws it back.
  describe "a guest typed but not added yet" do
    test "stays in the field when the box is ticked, and Create invites them to the meeting",
         %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => []})

      render_change(new_event_form(lv), %{"guest_email" => "ada@example.com"})
      tick_meeting(lv)

      assert has_element?(lv, ~s(#calendar-panel-guests input[value="ada@example.com"]))
      assert has_element?(lv, "#calendar-panel-meeting-guest-name")

      trace_surface(lv)
      book_meeting(lv)

      assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}
      assert %{attendee_email: "ada@example.com", guest_emails: []} = params
    end

    test "stays in the field when a reminder is chosen, and Create invites them to the meeting",
         %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => []})

      render_change(new_event_form(lv), %{"guest_email" => "ada@example.com", "meeting" => "true"})

      add_meeting_reminder(lv, "30-minutes")

      assert has_element?(lv, ~s(#calendar-panel-guests input[value="ada@example.com"]))

      trace_surface(lv)
      book_meeting(lv)

      assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}

      assert %{attendee_email: "ada@example.com", reminders: [%{value: 30, unit: "minutes"}]} =
               params
    end

    test "is cleared from the field once Add adds it", %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => []})

      render_change(new_event_form(lv), %{"guest_email" => "ada@example.com"})

      lv
      |> form("#calendar-panel-new-form", %{"guest_email" => "ada@example.com"})
      |> put_submitter("#calendar-panel-guest-add")
      |> render_submit()

      assert has_element?(lv, "#calendar-panel-guests li", "ada@example.com")
      assert has_element?(lv, ~s(#calendar-panel-guests input[name="guest_email"][value=""]))
    end

    # Enter in the field submits with the form's first submit button, Add.
    test "is cleared from the field once Enter adds it", %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => []})

      render_change(new_event_form(lv), %{"guest_email" => "ada@example.com"})

      render_submit(new_event_form(lv), %{
        "intent" => "add_guest",
        "guest_email" => "ada@example.com"
      })

      assert has_element?(lv, "#calendar-panel-guests li", "ada@example.com")
      assert has_element?(lv, ~s(#calendar-panel-guests input[name="guest_email"][value=""]))
    end

    test "gone by Create, the meeting is refused under the guest field, not made a plain event",
         %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => []})

      render_change(new_event_form(lv), %{"guest_email" => "ada@example.com", "meeting" => "true"})

      assert has_element?(lv, "#calendar-panel-create", "Create and invite")
      trace_surface(lv)

      book_meeting(lv, %{"guest_email" => ""})

      assert has_element?(lv, "#calendar-panel-guests", "Add a guest to send a Tymeslot meeting.")
      assert has_element?(lv, "#calendar-panel-create:not([disabled])")

      refute_received {:trace, _pid, :receive,
                       {:execute_create_ad_hoc_meeting, _request, _params}}

      refute_received {:provider_call, _task_pid, _payload}
    end
  end

  describe "the guest limit" do
    test "is the meeting's at Add, and the guest field gives way at it", %{
      conn: conn,
      integration: integration
    } do
      # The guest the meeting is with, and as many guests as a meeting takes.
      full = MeetingParams.max_guests()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => guest_addresses(full - 1)})
      tick_meeting(lv)

      assert has_element?(lv, "#calendar-panel-guest-add")

      render_submit(new_event_form(lv), %{
        "intent" => "add_guest",
        "guest_email" => "last@example.com"
      })

      assert has_element?(lv, "#calendar-panel-guests li", "last@example.com")
      refute has_element?(lv, "#calendar-panel-guest-add")

      assert has_element?(
               lv,
               "#calendar-panel-guests-full",
               "No more guests can be added to this meeting."
             )
    end

    test "is one fewer without a main participant, and Add past it is refused", %{
      conn: conn,
      integration: integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => guest_addresses(Guests.max_guests() - 1)})
      tick_meeting(lv)
      render_change(new_event_form(lv), %{"main_participant" => "false"})

      render_submit(new_event_form(lv), %{
        "intent" => "add_guest",
        "guest_email" => "last@example.com"
      })

      refute has_element?(lv, "#calendar-panel-guest-add")

      # Main participant back on, the meeting takes one more.
      render_change(new_event_form(lv), %{"main_participant" => "true"})
      assert has_element?(lv, "#calendar-panel-guest-add")

      render_change(new_event_form(lv), %{"main_participant" => "false"})

      render_submit(new_event_form(lv), %{
        "intent" => "create",
        "guest_email" => "one-more@example.com",
        "title" => "Planning"
      })

      refute has_element?(lv, "#calendar-panel-guests li", "one-more@example.com")
      assert render(lv) =~ "No more guests can be added to this meeting."
    end

    test "an address typed before the meeting filled is not counted once the field gives way",
         %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"guests" => guest_addresses(Guests.max_guests())})
      tick_meeting(lv)

      # With a main participant the meeting takes one more, typed here.
      render_change(new_event_form(lv), %{"guest_email" => "one-more@example.com"})

      # Without one it is full: the field goes, and the address with it.
      render_change(new_event_form(lv), %{"main_participant" => "false"})
      refute has_element?(lv, "#calendar-panel-guest-add")

      lv |> element("#calendar-panel-new-cancel") |> render_click()

      assert has_element?(
               lv,
               "#calendar-discard-draft",
               "#{Guests.max_guests()} guests haven't been invited yet."
             )
    end

    test "is an event's while the box is not ticked", %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open_meeting_draft(lv, integration, %{
        "guests" => guest_addresses(MeetingParams.max_guests())
      })

      render_submit(new_event_form(lv), %{
        "intent" => "add_guest",
        "guest_email" => "more@example.com"
      })

      assert has_element?(lv, "#calendar-panel-guests li", "more@example.com")
    end
  end

  test "more guests than a meeting takes are refused with the meeting's own limit", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    max = MeetingParams.max_guests()
    guests = for n <- 1..(max + 1), do: "guest#{n}@example.com"
    open_meeting_draft(lv, integration, %{"guests" => guests})
    tick_meeting(lv)
    trace_surface(lv)

    book_meeting(lv)

    assert has_element?(
             lv,
             "#calendar-panel [role=status]",
             "You can invite at most #{max} guests at once."
           )

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}},
                   100
  end
end
