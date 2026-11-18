defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceMeetingTest do
  @moduledoc """
  "Send as a Tymeslot meeting" in the side panel's New event state, on a
  desktop and on a phone (where the panel is a sheet): offered once the
  draft has a guest, it turns the draft into an ad hoc booking with the
  guest's name, the language of its emails, a note and reminder emails,
  and hands it to the dashboard (`{:execute_create_ad_hoc_meeting, params}`),
  which books it, flashes the outcome and tells the panel.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.MeetingParams
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
      send(test_pid, {:provider_call, self(), payload})
      {:ok, CreatedEvent.new(payload.uid)}
    end)

    context
  end

  defp hook(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp more_options(lv, integration, extra \\ %{}) do
    hook(
      lv,
      "calendar:more_options",
      Map.merge(
        %{
          "draft" => "d1",
          "title" => "",
          "start" => "2026-10-15T13:00",
          "end" => "2026-10-15T14:00",
          "all_day" => false,
          "calendar" => "#{integration.id}:work",
          "location" => "",
          "guests" => ["ada@example.com", "grace@example.com"],
          "free" => false
        },
        extra
      )
    )

    assert_reply(lv, %{opened: true})
  end

  defp new_form(lv), do: form(lv, "#calendar-panel-new-form")

  defp guests(count), do: Enum.map(1..count, &"guest#{&1}@example.com")

  defp add_reminder(lv, preset) do
    lv
    |> element(~s(#calendar-panel-meeting-reminders [data-testid="reminder-preset-#{preset}"]))
    |> render_click()
  end

  defp as_meeting(lv), do: render_change(new_form(lv), %{"meeting" => "true"})

  # What the panel hands the dashboard process is seen by tracing it.
  defp trace(lv), do: :erlang.trace(lv.pid, true, [:receive])

  defp create_meeting(lv, extra \\ %{}) do
    render_submit(
      new_form(lv),
      Map.merge(%{"intent" => "create", "guest_name" => "Ada Lovelace"}, extra)
    )
  end

  test "is offered once the draft has a guest, and says what it does", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration, %{"guests" => []})

    refute has_element?(lv, "#calendar-panel-meeting")

    render_submit(new_form(lv), %{"intent" => "add_guest", "guest_email" => "ada@example.com"})

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
    more_options(lv, integration, %{"guests" => []})

    render_change(new_form(lv), %{"guest_email" => "ada@example.com"})
    assert has_element?(lv, "#calendar-panel-meeting", "Send as a Tymeslot meeting")

    render_change(new_form(lv), %{"guest_email" => "ada@example.com", "meeting" => "true"})
    assert has_element?(lv, "#calendar-panel-meeting-guest-name")

    trace(lv)
    create_meeting(lv, %{"guest_email" => "ada@example.com", "meeting" => "true"})

    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, params}}
    assert %{attendee_email: "ada@example.com", guest_emails: []} = params
  end

  test "the place quick create parsed becomes the meeting's location", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration, %{"location" => "Room 4"})
    as_meeting(lv)

    trace(lv)
    create_meeting(lv)

    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, params}}
    assert %{location: {:custom, "Room 4"}} = params
  end

  describe "the guest limit" do
    test "is the meeting's at Add, and the guest field gives way at it", %{
      conn: conn,
      integration: integration
    } do
      # The guest the meeting is with, and as many guests as a meeting takes.
      full = MeetingParams.max_guests()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      more_options(lv, integration, %{"guests" => guests(full - 1)})
      as_meeting(lv)

      assert has_element?(lv, "#calendar-panel-guest-add")

      render_submit(new_form(lv), %{"intent" => "add_guest", "guest_email" => "last@example.com"})

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
      more_options(lv, integration, %{"guests" => guests(Guests.max_guests() - 1)})
      as_meeting(lv)
      render_change(new_form(lv), %{"main_participant" => "false"})

      render_submit(new_form(lv), %{"intent" => "add_guest", "guest_email" => "last@example.com"})
      refute has_element?(lv, "#calendar-panel-guest-add")

      # Main participant back on, the meeting takes one more.
      render_change(new_form(lv), %{"main_participant" => "true"})
      assert has_element?(lv, "#calendar-panel-guest-add")

      render_change(new_form(lv), %{"main_participant" => "false"})

      render_submit(new_form(lv), %{
        "intent" => "create",
        "guest_email" => "one-more@example.com",
        "title" => "Planning"
      })

      refute has_element?(lv, "#calendar-panel-guests li", "one-more@example.com")
      assert render(lv) =~ "No more guests can be added to this meeting."
    end

    test "is an event's while the box is not ticked", %{conn: conn, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      more_options(lv, integration, %{"guests" => guests(MeetingParams.max_guests())})

      render_submit(new_form(lv), %{"intent" => "add_guest", "guest_email" => "more@example.com"})

      assert has_element?(lv, "#calendar-panel-guests li", "more@example.com")
    end
  end

  test "the language of its emails starts as the organiser's own", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    Repo.update!(Changeset.change(user, locale: "de"))
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration)
    as_meeting(lv)

    assert has_element?(lv, ~s|#calendar-panel-meeting-locale option[value="de"][selected]|)
  end

  test "ticked, it asks for the guest's name, language and reminders in place of what a meeting cannot use",
       %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration)

    for id <- ~w(calendar-panel-new-all-day calendar-panel-new-free calendar-panel-new-location) do
      assert has_element?(lv, "##{id}")
    end

    as_meeting(lv)

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

    more_options(lv, integration, %{
      "all_day" => true,
      "start" => "2026-10-15",
      "end" => "2026-10-16"
    })

    as_meeting(lv)

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
    more_options(lv, integration)
    as_meeting(lv)
    add_reminder(lv, "1-hours")
    add_reminder(lv, "1-days")
    trace(lv)

    create_meeting(lv, %{
      "locale" => "fr",
      "description" => "Agenda: the Q3 roadmap."
    })

    assert_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, params}}

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
    more_options(lv, integration)
    as_meeting(lv)
    trace(lv)

    create_meeting(lv, %{"guest_name" => "  "})

    assert has_element?(lv, "#calendar-panel [role=status]", "Guest name is required")
    assert has_element?(lv, "#calendar-panel-create:not([disabled])")
    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _params}}, 100
  end

  test "a note typed before the box was ticked, past the meeting's limit, is refused as such", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration)
    render_change(new_form(lv), %{"description" => String.duplicate("a", 2001)})
    as_meeting(lv)
    trace(lv)

    create_meeting(lv)

    assert has_element?(
             lv,
             "#calendar-panel [role=status]",
             "The note to the guest is too long. Keep it to 2,000 characters or fewer."
           )

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _params}}, 100
  end

  test "the guest's name takes at most 255 characters", %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration)
    as_meeting(lv)

    assert has_element?(lv, ~s|#calendar-panel-meeting-guest-name[maxlength="255"]|)
  end

  test "a reminder ticked and the meeting then unticked creates a plain event, sending no meeting",
       %{conn: conn, integration: integration} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration)
    as_meeting(lv)
    add_reminder(lv, "1-hours")
    render_change(new_form(lv), %{"meeting" => "false"})
    refute has_element?(lv, "#calendar-panel-meeting-fields")
    trace(lv)

    render_submit(new_form(lv), %{"intent" => "create"})

    assert_receive {:provider_call, task_pid, %{summary: "New event"}}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    refute_received {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _params}}
    assert Repo.all(MeetingSchema) == []
  end

  test "more guests than a meeting takes are refused with the meeting's own limit", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    max = MeetingParams.max_guests()
    guests = for n <- 1..(max + 1), do: "guest#{n}@example.com"
    more_options(lv, integration, %{"guests" => guests})
    as_meeting(lv)
    trace(lv)

    create_meeting(lv)

    assert has_element?(
             lv,
             "#calendar-panel [role=status]",
             "You can invite at most #{max} guests at once."
           )

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _params}}, 100
  end

  test "past the meeting budget nothing is booked, and the panel says to wait", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    for _n <- 1..10, do: :ok = RateLimiter.check(:dashboard_quick_add_meeting, user.id)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration)
    as_meeting(lv)
    trace(lv)

    create_meeting(lv)

    assert has_element?(
             lv,
             "#calendar-panel [role=status]",
             "Too many new meetings. Please wait a moment."
           )

    refute_receive {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _params}}, 100
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
    more_options(lv, integration)
    as_meeting(lv)

    create_meeting(lv)

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
      more_options(lv, integration)
      as_meeting(lv)
      holder = hold_schedule(user.id)

      create_meeting(lv)
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
      more_options(lv, integration)
      as_meeting(lv)
      holder = hold_schedule(user.id)

      create_meeting(lv)
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
  end

  test "with its last guest removed the draft is an event again, written to the calendar", %{
    conn: conn,
    integration: integration
  } do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    more_options(lv, integration, %{"guests" => ["ada@example.com"]})
    as_meeting(lv)

    lv |> element("#calendar-panel-guests li button") |> render_click()

    refute has_element?(lv, "#calendar-panel-meeting")
    assert has_element?(lv, "#calendar-panel-new-location")
    trace(lv)

    render_submit(new_form(lv), %{"intent" => "create"})

    assert_receive {:provider_call, task_pid, %{summary: "New event"}}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    refute_received {:trace, _pid, :receive, {:execute_create_ad_hoc_meeting, _params}}
  end

  describe "on a phone" do
    test "the panel's sheet offers the same meeting, in rows a thumb can hit", %{
      conn: conn,
      integration: integration
    } do
      {:ok, lv, _html} =
        live(put_connect_params(conn, %{"viewport" => "phone"}), ~p"/dashboard/calendar")

      more_options(lv, integration)

      assert has_element?(lv, "#calendar-panel-meeting-row[class~='min-h-11']")

      as_meeting(lv)

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
