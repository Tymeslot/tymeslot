defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMeetingTest do
  @moduledoc """
  "Send as a Tymeslot meeting" in the side panel's New event state, on a
  desktop and on a phone (where the panel is a sheet): offered once the
  draft has a guest, it turns the draft into an ad hoc booking with the
  guest's name, the language of its emails, a note and reminder emails,
  and hands it to the dashboard (`{:execute_create_ad_hoc_meeting, request, params}`),
  which books it, flashes the outcome and tells the panel.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Phoenix.LiveView
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    forward_creates(self())
    context
  end

  test "the place quick create parsed becomes the meeting's location", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration, %{"location" => "Room 4"})
    tick_meeting(lv)

    trace_surface(lv)
    book_meeting(lv)

    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}
    assert %{location: {:custom, "Room 4"}} = params
  end

  test "the language of its emails starts as the organiser's own", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    Repo.update!(Changeset.change(user, locale: "de"))
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    tick_meeting(lv)

    assert has_element?(lv, ~s|#calendar-panel-meeting-locale option[value="de"][selected]|)
  end

  test "ticked, it asks for the guest's name, language and reminders in place of what a meeting cannot use",
       %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)

    for id <- ~w(calendar-panel-new-all-day calendar-panel-new-free calendar-panel-new-location) do
      assert has_element?(lv, "##{id}")
    end

    tick_meeting(lv)

    assert has_element?(lv, "#calendar-panel-meeting-guest-name")
    assert has_element?(lv, "#calendar-panel-meeting-locale")

    for preset <- ~w(30-minutes 1-hours 1-days) do
      assert has_element?(
               lv,
               ~s(#calendar-panel-meeting-reminders [data-testid="reminder-preset-#{preset}"])
             )
    end

    assert has_element?(
             lv,
             ~s(#calendar-panel-meeting-reminders [data-testid="reminder-custom-toggle"])
           )

    for id <- ~w(calendar-panel-new-all-day calendar-panel-new-free calendar-panel-new-location) do
      refute has_element?(lv, "##{id}")
    end

    assert has_element?(lv, "#calendar-panel-new-form", "Note to the guest")

    assert has_element?(
             lv,
             "#calendar-panel-new-form",
             "Included in the invitation and on the calendar entry."
           )

    assert has_element?(lv, ~s|#calendar-panel-new-description[maxlength="2000"]|)
    assert has_element?(lv, "#calendar-panel-create", "Create and invite")
  end

  test "an all-day draft becomes a timed one, as a meeting has times", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_meeting_draft(lv, integration, %{
      "all_day" => true,
      "start" => "2026-10-15",
      "end" => "2026-10-16"
    })

    tick_meeting(lv)

    assert has_element?(
             lv,
             ~s|#calendar-panel-new-form input[name="start"][value="2026-10-15T09:00"]|
           )

    assert has_element?(
             lv,
             ~s|#calendar-panel-new-form input[name="end"][value="2026-10-15T10:00"]|
           )
  end

  test "Create books the meeting with the first guest, the others as its guests, and what was chosen",
       %{conn: conn, user: user, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    tick_meeting(lv)
    add_meeting_reminder(lv, "1-hours")
    add_meeting_reminder(lv, "1-days")
    trace_surface(lv)

    book_meeting(lv, %{
      "locale" => "fr",
      "description" => "Agenda: the Q3 roadmap."
    })

    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, params}}

    assert %{
             title: "Meeting with Ada Lovelace",
             attendee_name: "Ada Lovelace",
             attendee_email: "ada@example.com",
             guest_emails: ["grace@example.com"],
             attendee_locale: "fr",
             attendee_timezone: "Europe/London",
             organizer_note: "Agenda: the Q3 roadmap.",
             reminders: [%{value: 1, unit: "hours"}, %{value: 1, unit: "days"}],
             calendar_id: "work"
           } = params

    assert params.organizer_user_id == user.id
    assert params.calendar_integration_id == integration.id
    assert DateTime.compare(params.start_time, ~U[2026-10-15 12:00:00Z]) == :eq

    meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: @task_timeout)
    assert meeting.attendee_email == "ada@example.com"

    assert Enum.map(meeting.reminders, &{&1["value"], &1["unit"]}) == [
             {1, "hours"},
             {1, "days"}
           ]

    assert [%{email: "grace@example.com", invited_by: :organizer}] =
             GuestQueries.list_for_meeting(meeting.id)

    eventually(fn -> render(lv) =~ "Meeting created and invitation sent" end,
      timeout: @task_timeout
    )

    refute has_element?(lv, "#calendar-panel")
    assert_push_event(lv, "calendar:events", %{reset: true, events: events})
    assert Enum.any?(events, &(&1.id == "booking-#{meeting.id}"))
  end

  test "without the guest's name nothing is booked, and the panel says why", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    tick_meeting(lv)
    trace_surface(lv)

    book_meeting(lv, %{"guest_name" => "  "})

    assert has_element?(lv, "#calendar-panel [role=status]", "Guest name is required")
    assert has_element?(lv, "#calendar-panel-create:not([disabled])")

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}},
                   100
  end

  test "a note typed before the box was ticked, past the meeting's limit, is refused as such", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    render_change(new_event_form(lv), %{"description" => String.duplicate("a", 2001)})
    tick_meeting(lv)
    trace_surface(lv)

    book_meeting(lv)

    assert has_element?(
             lv,
             "#calendar-panel [role=status]",
             "The note to the guest is too long. Keep it to 2,000 characters or fewer."
           )

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}},
                   100
  end

  test "the guest's name takes at most 255 characters", %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    tick_meeting(lv)

    assert has_element?(lv, ~s|#calendar-panel-meeting-guest-name[maxlength="255"]|)
  end

  test "a reminder ticked and the meeting then unticked creates a plain event, sending no meeting",
       %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    tick_meeting(lv)
    add_meeting_reminder(lv, "1-hours")
    render_change(new_event_form(lv), %{"meeting" => "false"})
    refute has_element?(lv, "#calendar-panel-meeting-fields")
    trace_surface(lv)

    render_submit(new_event_form(lv), %{"intent" => "create"})

    assert_receive {:provider_call, task_pid, %{summary: "New event"}}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    refute_received {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}}
    assert Repo.all(MeetingSchema) == []
  end

  test "past the meeting budget nothing is booked, and the panel says to wait", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    for _n <- 1..10, do: :ok = RateLimiter.check(:dashboard_quick_add_meeting, user.id)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    tick_meeting(lv)
    trace_surface(lv)

    book_meeting(lv)

    assert has_element?(
             lv,
             "#calendar-panel [role=status]",
             "Too many new meetings. Please wait a moment."
           )

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}},
                   100
  end

  test "a slot already taken keeps the panel open with Create offered again, and flashes why", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    insert(:meeting,
      organizer_user: user,
      start_time: ~U[2026-10-15 12:00:00Z],
      end_time: ~U[2026-10-15 13:00:00Z],
      status: "confirmed"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration)
    tick_meeting(lv)

    book_meeting(lv)

    eventually(fn -> render(lv) =~ "This time is no longer available." end,
      timeout: @task_timeout
    )

    assert has_element?(lv, "#calendar-panel-meeting-fields")
    assert has_element?(lv, "#calendar-panel-create:not([disabled])")
  end

  # Holds the organiser's schedule lock from a connection of its own, so a
  # booking started meanwhile waits on it until `release/1`: the panel stays
  # saving for as long as the test needs.
  defp hold_schedule(user_id) do
    test_pid = self()

    holder =
      spawn_link(fn ->
        :ok = Sandbox.checkout(Repo)

        Repo.transaction(fn ->
          MeetingConflictQueries.lock_organizer_schedule(user_id)
          send(test_pid, :schedule_held)

          receive do
            :release -> :ok
          end
        end)
      end)

    assert_receive :schedule_held
    holder
  end

  defp release(holder), do: send(holder, :release)

  # Every payload the hook was sent since the last call, as event lists.
  defp drain_events(%{proxy: {ref, _topic, _pid}} = lv, acc \\ []) do
    receive do
      {^ref, {:push_event, "calendar:events", %{events: events}}} ->
        drain_events(lv, [events | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp answer(lv, action, request),
    do:
      LiveView.send_update(lv.pid, CalendarSurface,
        id: "calendar",
        action: action,
        request: request
      )

  defp draft_drawn?(events), do: Enum.any?(events, &(&1.id == "draft-d1"))

  describe "closed while the meeting is being booked" do
    test "a refused booking leaves no draft behind on the grid", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      insert(:meeting,
        organizer_user: user,
        start_time: ~U[2026-10-15 12:00:00Z],
        end_time: ~U[2026-10-15 13:00:00Z],
        status: "confirmed"
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration)
      tick_meeting(lv)
      holder = hold_schedule(user.id)

      book_meeting(lv)
      assert has_element?(lv, "#calendar-panel-create[disabled]")
      drain_events(lv)
      lv |> element("#calendar-panel-new-cancel") |> render_click()

      refute has_element?(lv, "#calendar-panel")
      assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
      assert [events] = drain_events(lv)
      refute draft_drawn?(events)

      release(holder)

      eventually(fn -> render(lv) =~ "This time is no longer available." end,
        timeout: @task_timeout
      )

      refute Enum.any?(drain_events(lv), &draft_drawn?/1)
    end

    test "a booked meeting replaces the draft once the calendar reloads", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration)
      tick_meeting(lv)
      holder = hold_schedule(user.id)

      book_meeting(lv)
      assert has_element?(lv, "#calendar-panel-create[disabled]")
      lv |> element("#calendar-panel-new-cancel") |> render_click()

      assert_push_event(lv, "calendar:draft-cleared", %{draft: "d1"})
      drain_events(lv)
      release(holder)

      eventually(fn -> render(lv) =~ "Meeting created and invitation sent" end,
        timeout: @task_timeout
      )

      meeting = Repo.one!(MeetingSchema)
      assert_push_event(lv, "calendar:events", %{reset: true, events: events})
      assert Enum.any?(events, &(&1.id == "booking-#{meeting.id}"))
      refute draft_drawn?(events)
    end

    test "its answer leaves the next draft's meeting saving, which hears its own", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_meeting_draft(lv, integration, %{"draft" => "d2"})
      tick_meeting(lv)
      holder = hold_schedule(user.id)
      trace_surface(lv)

      book_meeting(lv)
      assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, request, _params}}

      # An earlier meeting, whose panel was closed while it saved, answers
      # now, either way, and the calendar is told as the dashboard tells it
      # (`CalendarRouting.to_mounted/2`); the dashboard's own handling reads
      # the database, which this meeting's booking holds until `release/1`.
      earlier = make_ref()
      answer(lv, :ad_hoc_meeting_failed, earlier)
      assert has_element?(lv, "#calendar-panel-meeting-fields")
      assert has_element?(lv, "#calendar-panel-create[disabled]")

      answer(lv, :ad_hoc_meeting_created, earlier)
      assert has_element?(lv, "#calendar-panel-create[disabled]")
      release(holder)

      # Its own answer closes it.
      assert_receive {:trace, _pid, :receive,
                      {:create_ad_hoc_meeting_result, ^request, {:ok, _}}},
                     @task_timeout

      eventually(fn -> render(lv) =~ "Meeting created and invitation sent" end,
        timeout: @task_timeout
      )

      refute has_element?(lv, "#calendar-panel")
    end
  end

  test "with its last guest removed the draft is an event again, written to the calendar", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_meeting_draft(lv, integration, %{"guests" => ["ada@example.com"]})
    tick_meeting(lv)

    lv |> element("#calendar-panel-guests li button") |> render_click()

    refute has_element?(lv, "#calendar-panel-meeting")
    assert has_element?(lv, "#calendar-panel-new-location")
    trace_surface(lv)

    render_submit(new_event_form(lv), %{"intent" => "create"})

    assert_receive {:provider_call, task_pid, %{summary: "New event"}}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    refute_received {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _request, _params}}
  end

  describe "on a phone" do
    test "the panel's sheet offers the same meeting, in rows a thumb can hit", %{
      conn: conn,
      integration: integration
    } do
      {:ok, lv, _html} =
        live(put_connect_params(conn, %{"viewport" => "phone"}), ~p"/dashboard/calendar")

      open_meeting_draft(lv, integration)

      assert has_element?(lv, "#calendar-panel-meeting-row[class~='min-h-11']")

      tick_meeting(lv)

      for preset <- ~w(30-minutes 1-hours 1-days) do
        assert has_element?(
                 lv,
                 ~s(#calendar-panel-meeting-reminders [data-testid="reminder-preset-#{preset}"])
               )
      end

      assert has_element?(lv, "#calendar-panel-meeting-guest-name")
    end
  end
end
