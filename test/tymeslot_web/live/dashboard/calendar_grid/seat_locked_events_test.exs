defmodule TymeslotWeb.Dashboard.CalendarGrid.SeatLockedEventsTest do
  @moduledoc """
  A group meeting's calendar event may not be moved, deleted or have its
  attendees changed from the grid while seats are held on it.

  The provider event is a copy of the meeting, not the meeting itself:
  dragging it changes only the organiser's calendar, leaving every
  participant booked at the old time with reschedule links pointing there;
  deleting it leaves them booked on a meeting with no calendar event; and its
  attendee list is not who holds a seat. The grid marks such events locked
  and hides those controls, and refuses the change server-side whatever the
  client sends. Each refusal is asserted on what it must not touch: the
  meeting row, the cached provider event, the provider itself, and the job
  queue.
  """

  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  # The seeded event starts at 10:00 UTC and the drop asks for 14:00 in the
  # organiser's timezone; both are rendered in that timezone, so the minute
  # offsets below are what the block carries before and after a move.
  @original_start_minutes 780
  @moved_start_minutes 840

  @locked_message "This is a group booking. Move it, cancel it or change who attends from the meeting instead."

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Phoenix.HTML
  alias Tymeslot.Repo
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.NotificationFlows

  setup :setup_dashboard_user

  setup %{user: user} do
    {:ok, integration: insert(:calendar_integration, user: user, is_active: true)}
  end

  # A meeting plus the provider event Tymeslot wrote for it, linked by uid.
  defp booked_event(user, integration, opts) do
    today = Date.utc_today()

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        capacity: if(opts[:seats], do: 2, else: 1),
        start_time: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
        end_time: DateTime.new!(today, ~T[11:00:00], "Etc/UTC")
      )

    if opts[:seats] do
      insert(:participant, meeting: meeting)
    end

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: meeting.calendar_uid,
        summary: "Group Workshop",
        attendees: [%{"email" => "seat-holder@example.com"}],
        start_at: DateTime.new!(today, ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(today, ~T[11:00:00], "Etc/UTC"),
        all_day: false,
        created_by_tymeslot: true
      )

    %{meeting: meeting, event: event}
  end

  defp drop_params(event) do
    %{
      "event-id" => to_string(event.id),
      "new-date" => Date.to_iso8601(Date.utc_today()),
      "new-hour" => "14",
      "new-minute" => "0",
      "new-end-hour" => "15",
      "new-end-minute" => "0"
    }
  end

  describe "a slot with live seats on it" do
    setup %{user: user, integration: integration} do
      stub_provider_writes()
      booked_event(user, integration, seats: true)
    end

    test "renders locked, with no drag affordance and no resize handle",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      block = event_block(lv, event.id)

      assert block =~ ~s(data-draggable="false")
      assert block =~ html_escape(@locked_message)
      refute block =~ "data-resize-handle"
    end

    test "answers a drag on the locked block by saying why it cannot move", ctx do
      {lv, jobs} = mount_grid(ctx.conn)

      block = event_block(lv, ctx.event.id)
      assert block =~ ~s(data-locked="true")
      # Pressing and dragging must not select text across neighbouring events.
      assert has_element?(lv, "[id^='event-#{ctx.event.id}-'].select-none")
      refute has_element?(lv, "[role='alert']", "This is a group booking")

      lv |> element("#calendar-grid") |> render_hook("locked_event_drag", %{})

      assert has_element?(lv, "[role='alert']", "This is a group booking.")
      assert_untouched(ctx, jobs)
    end

    test "refuses a drop and leaves the event where it was", ctx do
      {lv, jobs} = mount_grid(ctx.conn)

      lv
      |> element("#calendar-grid")
      |> render_hook("event_dropped", drop_params(ctx.event))

      assert render(lv) =~ html_escape(@locked_message)
      assert event_block(lv, ctx.event.id) =~ ~s(data-start-minutes="#{@original_start_minutes}")
      assert_untouched(ctx, jobs)
    end

    test "refuses a resize", ctx do
      {lv, jobs} = mount_grid(ctx.conn)

      lv
      |> element("#calendar-grid")
      |> render_hook("event_resized", %{
        "event-id" => to_string(ctx.event.id),
        "event-date" => Date.to_iso8601(Date.utc_today()),
        "new-end-hour" => "13",
        "new-end-minute" => "0"
      })

      assert render(lv) =~ html_escape(@locked_message)
      assert event_block(lv, ctx.event.id) =~ ~s(data-duration-minutes="60")
      assert_untouched(ctx, jobs)
    end

    test "refuses a time change typed into the detail modal", ctx do
      {lv, jobs} = mount_grid(ctx.conn)
      open_event(lv, ctx.event)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_time", %{
        "start-date" => Date.to_iso8601(Date.utc_today()),
        "start-time" => "14:00",
        "end-date" => Date.to_iso8601(Date.utc_today()),
        "end-time" => "15:00"
      })

      assert render(lv) =~ html_escape(@locked_message)
      assert event_block(lv, ctx.event.id) =~ ~s(data-start-minutes="#{@original_start_minutes}")
      assert_untouched(ctx, jobs)
    end

    test "the detail modal shows the time, the attendees and no delete read-only",
         %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = open_event(lv, event)

      assert html =~ "event-time-locked-note"
      assert html =~ html_escape(@locked_message)
      refute html =~ ~s(id="event-time-form")
      refute html =~ ~s(id="event-all-day")

      # The attendee is listed, but cannot be removed and none can be added.
      assert html =~ "seat-holder@example.com"
      refute html =~ "request_remove_attendee"
      refute html =~ "add_event_attendee"

      refute html =~ "request_delete_event"
      refute html =~ "Delete event"
    end

    test "refuses a recurrence change typed into the detail modal", ctx do
      {lv, jobs} = mount_grid(ctx.conn)
      open_event(lv, ctx.event)

      lv
      |> element("#calendar-grid")
      |> render_hook("update_event_recurrence", %{
        "freq" => "weekly",
        "interval" => "1",
        "by_day" => ["mo"],
        "end_type" => "never"
      })

      html = render(lv)
      assert html =~ html_escape(@locked_message)
      refute html =~ "Repeats weekly"
      assert_untouched(ctx, jobs)
    end

    test "the detail modal hides the recurrence editor", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      html = open_event(lv, event)

      refute html =~ "Does not repeat"
    end

    test "refuses a delete request instead of opening the confirmation", ctx do
      {lv, jobs} = mount_grid(ctx.conn)
      open_event(lv, ctx.event)

      lv |> element("#calendar-grid") |> render_hook("request_delete_event", %{})

      # The flash is relayed to the parent LiveView, so it lands on the next
      # render rather than in the hook's own reply.
      html = render(lv)
      assert html =~ html_escape(@locked_message)
      refute html =~ "confirm-delete-event-modal"
      assert_untouched(ctx, jobs)
    end

    # Every confirmed delete, with or without notifying attendees, reaches the
    # LiveView as this message; a stale grid or a forged message must not get
    # the event deleted.
    test "refuses a delete that reaches the LiveView regardless", ctx do
      {lv, jobs} = mount_grid(ctx.conn)

      for notify? <- [true, false] do
        send(
          lv.pid,
          {:execute_delete_event,
           NotificationFlows.build_delete_payload(ctx.event, ctx.user.id, notify?)}
        )

        assert render(lv) =~ html_escape(@locked_message)
      end

      assert event_block(lv, ctx.event.id) =~ "Group Workshop"
      assert_untouched(ctx, jobs)
    end

    test "refuses adding an attendee", ctx do
      {lv, jobs} = mount_grid(ctx.conn)
      open_event(lv, ctx.event)

      lv
      |> element("#calendar-grid")
      |> render_hook("add_event_attendee", %{"email" => "colleague@example.com"})

      html = render(lv)
      assert html =~ html_escape(@locked_message)
      refute html =~ "colleague@example.com"
      assert_untouched(ctx, jobs)
    end

    test "refuses removing an attendee", ctx do
      {lv, jobs} = mount_grid(ctx.conn)
      open_event(lv, ctx.event)

      lv
      |> element("#calendar-grid")
      |> render_hook("request_remove_attendee", %{"email" => "seat-holder@example.com"})

      assert render(lv) =~ html_escape(@locked_message)

      lv |> element("#calendar-grid") |> render_hook("confirm_remove_attendee", %{})

      assert render(lv) =~ "seat-holder@example.com"
      assert_untouched(ctx, jobs)
    end
  end

  describe "a group slot whose seats were all cancelled" do
    setup %{user: user, integration: integration} do
      %{meeting: meeting} = booked = booked_event(user, integration, seats: true)

      Repo.update_all(Ecto.assoc(meeting, :participants),
        set: [cancelled_at: DateTime.utc_now(:second)]
      )

      booked
    end

    test "is no longer locked", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert event_block(lv, event.id) =~ ~s(data-draggable="true")
    end
  end

  describe "a booking nobody holds a seat on" do
    setup %{user: user, integration: integration} do
      booked_event(user, integration, seats: false)
    end

    test "stays draggable", %{conn: conn, event: event} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      block = event_block(lv, event.id)

      assert block =~ ~s(data-draggable="true")
      assert block =~ "data-resize-handle"
      refute block =~ "data-locked"
    end

    test "moves when dropped", %{conn: conn, event: event} do
      # Moving a booking re-reads the host's calendar before it is written.
      Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        {:ok, []}
      end)

      # The move is written to the provider from a background Task. Left
      # unanswered, that write crashes and reverts the grid, racing the
      # assertion below; answering it also proves the move reached the
      # calendar rather than only the screen.
      test_pid = self()

      Mox.stub(Tymeslot.CalendarMock, :update_event, fn uid, _data, _context ->
        send(test_pid, {:provider_update, uid})
        :ok
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> element("#calendar-grid")
        |> render_hook("event_dropped", drop_params(event))

      assert html =~ "Group Workshop"
      assert_receive {:provider_update, uid}
      assert uid == event.uid
      assert event_block(lv, event.id) =~ ~s(data-start-minutes="#{@moved_start_minutes}")
    end
  end

  defp open_event(lv, event), do: lv |> element("[id^='event-#{event.id}-']") |> render_click()

  defp html_escape(text),
    do: text |> HTML.html_escape() |> HTML.safe_to_string()

  # Any write that slipped past the lock would reach the provider through
  # these; the stubs report it so the refusal tests can show none did.
  defp stub_provider_writes do
    test_pid = self()

    Mox.stub(Tymeslot.CalendarMock, :update_event, fn uid, _data, _context ->
      send(test_pid, {:provider_write, :update, uid})
      :ok
    end)

    Mox.stub(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
      send(test_pid, {:provider_write, :delete, uid})
      :ok
    end)
  end

  # Opening the calendar asks for a sync of each integration, so the jobs
  # queued once the page has settled are the baseline a refusal must leave
  # unchanged.
  defp mount_grid(conn) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    render(lv)
    {lv, all_enqueued([])}
  end

  # What a refused change must leave alone: the meeting, the cached provider
  # event, the provider calendar, and the job queue (no attendee or seat
  # notification, no sync beyond the page's own).
  defp assert_untouched(%{meeting: meeting, event: event}, jobs_before) do
    stored_meeting = Repo.reload!(meeting)

    assert {stored_meeting.start_time, stored_meeting.end_time, stored_meeting.status} ==
             {meeting.start_time, meeting.end_time, meeting.status}

    stored_event = Repo.reload!(event)

    assert {stored_event.start_at, stored_event.end_at, stored_event.recurrence_rule,
            stored_event.attendees, stored_event.sync_state} ==
             {event.start_at, event.end_at, event.recurrence_rule, event.attendees,
              event.sync_state}

    refute_receive {:provider_write, _kind, _uid}
    assert Enum.map(all_enqueued([]), & &1.id) == Enum.map(jobs_before, & &1.id)
  end

  # The rendered markup of one event block, so an assertion about a single
  # event cannot pass on some other element of the page.
  defp event_block(lv, event_id) do
    lv |> element("[id^='event-#{event_id}-']") |> render()
  end
end
