defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceGuestsTest do
  @moduledoc """
  Guests in the side panel: Invite saves the list and emails the new guest
  once the calendar accepts it, removing asks first and emails the removed
  guest the same way, a group
  booking's seats lock both, and "Tell guests" sends one update for what
  changed since the panel opened.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Phoenix.LiveView, only: [send_update: 3]
  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface

  @task_timeout 5_000

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:provider_update, self(), payload})
      :ok
    end)

    review =
      event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60,
        attendees: [%{"email" => "ada@example.com", "display_name" => "Ada Lovelace"}]
      )

    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{review.id}"})

    Map.merge(context, %{lv: lv, review: review})
  end

  defp await_provider_update(lv) do
    assert_receive {:provider_update, task_pid, payload}, @task_timeout
    ref = Process.monitor(task_pid)
    assert_receive {:DOWN, ^ref, :process, ^task_pid, _reason}, @task_timeout
    render(lv)
    render(lv)
    payload
  end

  defp invite(lv, email),
    do: lv |> form("#calendar-panel-guest-form") |> render_submit(%{"email" => email})

  defp emails(payload), do: Enum.map(payload.attendees, &(Map.get(&1, :email) || &1["email"]))

  test "lists the guests with a remove button each", %{lv: lv} do
    assert has_element?(lv, "#calendar-panel-guests li", "Ada Lovelace")

    assert has_element?(
             lv,
             ~s|#calendar-panel-guests button[phx-value-email="ada@example.com"]|
           )
  end

  test "Invite saves the list and emails the new guest once the calendar accepts it", %{
    lv: lv,
    integration: integration,
    review: review
  } do
    invite(lv, "  Grace@Example.com ")

    payload = await_provider_update(lv)
    assert emails(payload) == ["ada@example.com", "grace@example.com"]

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_calendar_invitation",
        "attendee_email" => "grace@example.com",
        "method" => "request"
      }
    )

    assert has_element?(lv, "#calendar-toast", "Invited grace@example.com.")
    refute has_element?(lv, "#calendar-undo")
    assert has_element?(lv, "#calendar-panel-guests li", "grace@example.com")

    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, review.uid)
    assert Enum.map(row.attendees, & &1["email"]) == ["ada@example.com", "grace@example.com"]
  end

  test "the reason an address is not invited is said under the field, not in a flash, and typing clears it",
       %{lv: lv} do
    invite(lv, "not an email")

    assert has_element?(lv, "#calendar-panel-guest-form", "Enter a valid email address.")
    refute has_element?(lv, "[id$='flash-group-warning']", "Enter a valid email address.")

    lv
    |> form("#calendar-panel-guest-form")
    |> render_change(%{"email" => "grace@"})

    refute has_element?(lv, "#calendar-panel-guest-form", "Enter a valid email address.")
  end

  test "an address that is not an email, or a guest already invited, sends nothing", %{lv: lv} do
    invite(lv, "not an email")
    assert has_element?(lv, "#calendar-panel-guest-form", "Enter a valid email address.")

    invite(lv, "ADA@example.com")
    assert has_element?(lv, "#calendar-panel-guest-form", "ada@example.com is already a guest.")

    refute_enqueued(worker: EmailWorker)
    refute_receive {:provider_update, _pid, _payload}, 100
  end

  test "removing asks first; Cancel keeps the guest and sends nothing", %{lv: lv} do
    lv
    |> element(~s|#calendar-panel-guests button[phx-value-email="ada@example.com"]|)
    |> render_click()

    assert has_element?(lv, "#calendar-remove-guest", "Remove ada@example.com?")

    lv |> element("#calendar-remove-guest-cancel") |> render_click()

    refute has_element?(lv, "#calendar-remove-guest")
    assert has_element?(lv, "#calendar-panel-guests li", "Ada Lovelace")
    refute_enqueued(worker: EmailWorker)
  end

  test "closing the panel drops the removal question", %{lv: lv} do
    lv
    |> element(~s|#calendar-panel-guests button[phx-value-email="ada@example.com"]|)
    |> render_click()

    assert has_element?(lv, "#calendar-remove-guest")

    lv |> element("#calendar-canvas") |> render_hook("panel:close", %{})

    refute has_element?(lv, "#calendar-remove-guest")
    refute_enqueued(worker: EmailWorker)
  end

  test "confirming the removal tells the guest and saves the shorter list", %{lv: lv} do
    lv
    |> element(~s|#calendar-panel-guests button[phx-value-email="ada@example.com"]|)
    |> render_click()

    lv |> element("#calendar-remove-guest-confirm") |> render_click()

    payload = await_provider_update(lv)
    assert emails(payload) == []

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_calendar_invitation",
        "attendee_email" => "ada@example.com",
        "method" => "cancel"
      }
    )

    refute has_element?(lv, "#calendar-panel-guests li", "Ada Lovelace")
    assert has_element?(lv, "#calendar-toast", "Removed ada@example.com.")
  end

  # A live group booking is drawn as the booking, never as its calendar copy,
  # so the copy (and the seat lock that guards it) is out of reach here; the
  # lock itself is covered in `EditGuardTest`.
  defp group_booking(conn, user, integration) do
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        capacity: 2,
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 11:00:00Z]
      )

    insert(:participant, meeting: meeting)

    workshop =
      event(integration, "work", "Group workshop", ~U[2026-10-15 10:00:00Z], 60,
        uid: meeting.calendar_uid,
        attendees: [%{"email" => "seat-holder@example.com"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})
    assert_reply(lv, %{events: events})

    {lv, meeting, workshop, events}
  end

  test "a live group booking is drawn as the booking, not its calendar copy", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {_lv, meeting, workshop, events} = group_booking(conn, user, integration)

    assert %{kind: "booking"} = Enum.find(events, &(&1.id == "booking-#{meeting.id}"))
    refute Enum.any?(events, &(&1.id == "event-#{workshop.id}"))
  end

  test "a live group booking offers no guest editing or panel", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    {lv, meeting, workshop, _events} = group_booking(conn, user, integration)

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:open", %{"id" => "booking-#{meeting.id}"})

    assert has_element?(lv, "#calendar-preview")
    refute has_element?(lv, "#calendar-preview-edit")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "booking-#{meeting.id}"})

    refute has_element?(lv, "#calendar-panel-guests")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{workshop.id}"})

    refute has_element?(lv, "#calendar-panel-guests")
    refute_enqueued(worker: EmailWorker)
  end

  test "the header settles on Saved once the guest write has landed", %{lv: lv} do
    invite(lv, "grace@example.com")

    await_provider_update(lv)

    assert has_element?(lv, "#calendar-panel-status", "Saved")
    refute has_element?(lv, "#calendar-panel-status", "Saving")
  end

  test "the organiser's own address is not invited", %{lv: lv, user: user} do
    invite(lv, String.upcase(user.email))

    refute_enqueued(worker: EmailWorker)
    refute_receive {:provider_update, _pid, _payload}, 100
    refute has_element?(lv, "#calendar-panel-guests li", user.email)
  end

  test "an event already at the guest limit takes no more", %{
    conn: conn,
    integration: integration
  } do
    crowd = for n <- 1..50, do: %{"email" => "guest#{n}@example.com"}
    full = event(integration, "work", "Town hall", ~U[2026-10-15 15:00:00Z], 60, attendees: crowd)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{full.id}"})

    invite(lv, "one-too-many@example.com")

    assert has_element?(lv, "#calendar-panel-guest-form", "An event can have at most 50 guests.")
    refute_enqueued(worker: EmailWorker)
    refute_receive {:provider_update, _pid, _payload}, 100
  end

  describe "while the event moves to another calendar" do
    setup %{conn: conn, user: user, review: review} do
      other =
        insert(:calendar_integration,
          user: user,
          name: "Other account",
          provider: "google",
          is_active: true,
          calendar_list: [%{"id" => "other", "name" => "Other", "selected" => true}]
        )

      test_pid = self()

      stub(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
        send(test_pid, {:create_held, self()})

        receive do
          :release -> {:ok, CreatedEvent.new(payload.uid)}
        end
      end)

      stub(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:edit", %{"id" => "event-#{review.id}"})

      lv
      |> form("#calendar-panel-calendar-form")
      |> render_change(%{"calendar" => "#{other.id}:other"})

      assert_receive {:create_held, task_pid}, @task_timeout
      on_exit(fn -> send(task_pid, :release) end)
      %{lv: lv}
    end

    test "inviting is refused", %{lv: lv} do
      invite(lv, "grace@example.com")

      assert has_element?(lv, "#calendar-panel-status", "moving to another calendar")
      refute_enqueued(worker: EmailWorker)
    end

    test "removing is refused and emails nobody", %{lv: lv} do
      lv
      |> element(~s|#calendar-panel-guests button[phx-value-email="ada@example.com"]|)
      |> render_click()

      refute has_element?(lv, "#calendar-remove-guest")
      assert has_element?(lv, "#calendar-panel-status", "moving to another calendar")
      refute_enqueued(worker: EmailWorker)
    end
  end

  describe "telling guests" do
    test "no note while nothing guests can see has changed", %{lv: lv} do
      refute has_element?(lv, "#calendar-panel-untold")
    end

    test "a change since the panel opened offers Tell guests, which sends one update", %{
      lv: lv,
      review: review
    } do
      review |> Changeset.change(location: "Room 9") |> Repo.update!()
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :events_updated)
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :reload)

      assert has_element?(
               lv,
               "#calendar-panel-untold",
               "Guests haven't been told about these changes"
             )

      lv |> element("#calendar-panel-tell-guests") |> render_click()

      assert_enqueued(
        worker: Worker,
        args: %{
          "event_id" => review.id,
          "kind" => "provider_calendar_event",
          "action" => "update"
        }
      )

      refute has_element?(lv, "#calendar-panel-untold")
      assert has_element?(lv, "#calendar-toast", "Guests will get an update.")
    end

    test "a later change brings the note back after Tell guests cleared it", %{
      lv: lv,
      review: review
    } do
      review |> Changeset.change(location: "Room 9") |> Repo.update!()
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :events_updated)
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :reload)
      lv |> element("#calendar-panel-tell-guests") |> render_click()
      refute has_element?(lv, "#calendar-panel-untold")

      lv |> element("#calendar-panel-title") |> render_blur(%{"value" => "Design review, moved"})

      assert has_element?(lv, "#calendar-panel-untold", "Guests haven't been told")
    end

    test "an event without guests never shows the note", %{conn: conn, integration: integration} do
      solo = event(integration, "work", "Focus", ~U[2026-10-15 09:00:00Z])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:edit", %{"id" => "event-#{solo.id}"})

      solo |> Changeset.change(location: "Room 9") |> Repo.update!()
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :events_updated)
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :reload)

      refute has_element?(lv, "#calendar-panel-untold")
    end

    # The note is not drawn for these, so the event is forced as a crafted
    # client would send it. The panel shows the changed place, so the event
    # differs from the one the panel opened on and `tell/1` gets as far as
    # the domain, which refuses it (`Changes.tell_guests/5`).
    # `place` finds the changed place: a field, or text on an event that
    # cannot be edited.
    defp change_and_force_tell(conn, event, refusal, place) do
      lv = open_panel(conn, event)

      event |> Changeset.change(location: "Room 9") |> Repo.update!()
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :events_updated)
      send_update(lv.pid, CalendarSurface, id: "calendar", action: :reload)

      assert has_element?(lv, place)

      refute has_element?(lv, "#calendar-panel-untold")
      refute has_element?(lv, "#app-flash-group", refusal)

      lv |> element("#calendar-canvas") |> render_hook("panel:tell_guests", %{})
      lv
    end

    test "an event someone else organises offers no note and a forced Tell guests sends nothing",
         %{conn: conn, integration: integration} do
      lv =
        change_and_force_tell(
          conn,
          theirs(integration),
          "Someone else organises this event",
          ~s|#calendar-panel-location[value="Room 9"]|
        )

      nothing_sent()
      assert has_element?(lv, "#app-flash-group", "Someone else organises this event")
      refute has_element?(lv, "#calendar-toast", "Guests will get an update.")
    end

    test "an event on a read-only calendar offers no note and a forced Tell guests sends nothing",
         %{conn: conn, integration: integration} do
      integration
      |> Changeset.change(
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
        ]
      )
      |> Repo.update!()

      shared =
        event(integration, "shared", "Team offsite", ~U[2026-10-16 09:00:00Z], 60,
          attendees: [%{"email" => "ada@example.com"}]
        )

      lv =
        change_and_force_tell(
          conn,
          shared,
          "This calendar is read-only.",
          "#calendar-panel-location-text"
        )

      nothing_sent()
      assert has_element?(lv, "#app-flash-group", "This calendar is read-only.")
      refute has_element?(lv, "#calendar-toast", "Guests will get an update.")
    end
  end

  describe "an event someone else organises" do
    test "lists its guests without Invite or remove", %{conn: conn, integration: integration} do
      lv = open_panel(conn, theirs(integration))

      assert has_element?(lv, "#calendar-panel-guests li", "ada@example.com")
      refute has_element?(lv, "#calendar-panel-guest-form")
      refute has_element?(lv, "#calendar-panel-guests button[phx-value-email]")
      assert has_element?(lv, "#calendar-panel-guests-not-organiser")
    end

    test "a forced invite emails nobody and saves nothing", %{
      conn: conn,
      integration: integration
    } do
      lv = open_panel(conn, theirs(integration))

      lv
      |> element("#calendar-canvas")
      |> render_hook("panel:guest_invite", %{"email" => "grace@example.com"})

      nothing_sent()
      refute_receive {:provider_update, _pid, _payload}, 100
      assert has_element?(lv, "#app-flash-group", "Someone else organises this event")
    end

    test "a forced removal asks nothing, emails nobody and saves nothing", %{
      conn: conn,
      integration: integration
    } do
      lv = open_panel(conn, theirs(integration))

      lv
      |> element("#calendar-canvas")
      |> render_hook("panel:guest_remove", %{"email" => "ada@example.com"})

      refute has_element?(lv, "#calendar-remove-guest")
      lv |> element("#calendar-canvas") |> render_hook("panel:guest_remove_confirm", %{})

      nothing_sent()
      refute_receive {:provider_update, _pid, _payload}, 100
      assert has_element?(lv, "#app-flash-group", "Someone else organises this event")
    end
  end

  defp theirs(integration),
    do:
      event(integration, "work", "Their standup", ~U[2026-10-15 09:00:00Z], 30,
        organiser: %{"email" => "boss@elsewhere.example"},
        attendees: [%{"email" => "boss@elsewhere.example"}, %{"email" => "ada@example.com"}]
      )

  defp open_panel(conn, event) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{event.id}"})

    lv
  end

  defp nothing_sent do
    assert all_enqueued(worker: Worker) == []
    assert all_enqueued(worker: EmailWorker) == []
  end
end
