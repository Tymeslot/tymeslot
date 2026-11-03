defmodule TymeslotWeb.HostManagedMeetingWebTest do
  @moduledoc """
  The public pages refuse to move or cancel a meeting confirmed from a poll,
  and the host moves it from the dashboard instead of asking anyone to.
  """
  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Ecto.Changeset
  alias Tymeslot.Availability.TimeOff
  alias Tymeslot.EmailServiceMock
  alias Tymeslot.Meetings.{Guests, MeetingSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    %{user: user, profile: profile} = seed_booking_account("1", "pollhost", "Etc/UTC")

    user =
      Repo.update!(Changeset.change(user, onboarding_completed_at: DateTime.utc_now(:second)))

    # Whole minutes, as the dashboard's time input has no seconds.
    start = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)
    start = %{start | second: 0}

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        title: "Team offsite",
        meeting_type: "Team offsite",
        attendee_name: "Ada",
        attendee_email: "ada@example.com",
        status: :confirmed,
        managed_by_host: true,
        meeting_type_id: nil,
        start_time: start,
        end_time: DateTime.add(start, 45, :minute)
      )

    {:ok, _guests} =
      Guests.create_for_meeting(meeting.id, ["ada@example.com", "bob@example.com"], :organizer)

    %{user: user, profile: profile, meeting: meeting}
  end

  for action <- ["cancel", "reschedule"] do
    test "the public #{action} page sends the visitor away with an explanation", ctx do
      assert {:error, {:redirect, %{to: to, flash: flash}}} =
               live(
                 build_conn(),
                 "/#{ctx.profile.username}/meeting/#{ctx.meeting.uid}/#{unquote(action)}"
               )

      assert to == "/#{ctx.profile.username}"
      assert flash["error"] =~ "only its host can move or cancel it"
    end
  end

  test "the booking page opened with its uid sends the visitor away with an explanation",
       ctx do
    assert {:error, {_redirect, %{to: to, flash: flash}}} =
             live(
               build_conn(),
               "/#{ctx.profile.username}?timezone=UTC&reschedule_meeting_uid=#{ctx.meeting.uid}"
             )

    assert to == "/#{ctx.profile.username}?timezone=UTC"
    assert flash["error"] =~ "only its host can move it"
  end

  test "the dashboard card names the poll, not a booker, and lists everyone as a guest", ctx do
    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    assert has_element?(view, "h2", "Team offsite")
    refute has_element?(view, "h2", "Ada")
    assert has_element?(view, "[data-testid='poll-meeting-badge']")
    refute has_element?(view, "[data-testid='meeting-type']")
    refute render(view) =~ "Attendee Email"
    assert render(view) =~ "bob@example.com"
  end

  test "the host moves it from the dashboard and everyone is told", ctx do
    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view
    |> element("[phx-click='show_reschedule_modal'][phx-value-id='#{ctx.meeting.id}']")
    |> render_click()

    assert has_element?(view, "[data-testid='host-move-form']")
    refute render(view) =~ "Send a reschedule request"

    new_start = DateTime.add(ctx.meeting.start_time, 1, :day)

    view
    |> form("[data-testid='host-move-form']", %{"move" => %{"start" => local(new_start)}})
    |> render_submit()

    moved = Repo.get!(MeetingSchema, ctx.meeting.id)
    assert moved.start_time == new_start
    assert DateTime.diff(moved.end_time, moved.start_time, :minute) == 45
    assert render(view) =~ "Meeting moved"
    refute has_element?(view, "[data-testid='host-move-form']")

    # The notices to the host and every guest go out from the reschedule job.
    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_reschedule_emails", "meeting_id" => ctx.meeting.id}
    )
  end

  test "the dashboard explains a time the host is already booked at", ctx do
    taken = DateTime.add(ctx.meeting.start_time, 1, :day)

    insert(:meeting,
      organizer_user: ctx.user,
      organizer_email: ctx.user.email,
      status: :confirmed,
      start_time: taken,
      end_time: DateTime.add(taken, 30, :minute)
    )

    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view
    |> element("[phx-click='show_reschedule_modal'][phx-value-id='#{ctx.meeting.id}']")
    |> render_click()

    html =
      view
      |> form("[data-testid='host-move-form']", %{"move" => %{"start" => local(taken)}})
      |> render_submit()

    assert html =~ "You already have a meeting at that time."
    assert Repo.get!(MeetingSchema, ctx.meeting.id).start_time == ctx.meeting.start_time
  end

  test "the dashboard says why when the meeting was cancelled while the dialog was open", ctx do
    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view
    |> element("[phx-click='show_reschedule_modal'][phx-value-id='#{ctx.meeting.id}']")
    |> render_click()

    Repo.update!(Changeset.change(ctx.meeting, status: :cancelled))

    html =
      view
      |> form("[data-testid='host-move-form']", %{
        "move" => %{"start" => local(DateTime.add(ctx.meeting.start_time, 1, :day))}
      })
      |> render_submit()

    assert html =~ "Cannot reschedule a cancelled meeting"
    refute html =~ "could not be moved"
    assert Repo.get!(MeetingSchema, ctx.meeting.id).start_time == ctx.meeting.start_time
  end

  test "the dashboard explains a time inside the host's time off", ctx do
    away = DateTime.add(ctx.meeting.start_time, 1, :day)
    day = DateTime.to_date(away)
    {:ok, _period} = TimeOff.create(ctx.profile.id, %{starts_on: day, ends_on: day})

    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view
    |> element("[phx-click='show_reschedule_modal'][phx-value-id='#{ctx.meeting.id}']")
    |> render_click()

    html =
      view
      |> form("[data-testid='host-move-form']", %{"move" => %{"start" => local(away)}})
      |> render_submit()

    assert html =~
             "This time falls within your time off. Change or remove the time off to move the meeting there."

    refute html =~ "could not be moved"
    assert Repo.get!(MeetingSchema, ctx.meeting.id).start_time == ctx.meeting.start_time
  end

  test "the host's moves count against the dashboard reschedule limit", ctx do
    RateLimiter.clear_all()
    on_exit(&RateLimiter.clear_all/0)

    for _i <- 1..20 do
      assert :ok = RateLimiter.check(:dashboard_reschedule, ctx.user.id)
    end

    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view
    |> element("[phx-click='show_reschedule_modal'][phx-value-id='#{ctx.meeting.id}']")
    |> render_click()

    html =
      view
      |> form("[data-testid='host-move-form']", %{
        "move" => %{"start" => local(DateTime.add(ctx.meeting.start_time, 1, :day))}
      })
      |> render_submit()

    assert html =~ "reached the limit"
    assert Repo.get!(MeetingSchema, ctx.meeting.id).start_time == ctx.meeting.start_time
  end

  # Next year's changeover, so the dates are always ahead. The meeting starts
  # at 10:00 Berlin time on the Saturday before and moves to 10:00 on the
  # Monday after, across the clock change.
  for {month, change, monday_utc_hour} <- [
        {10, "summer time ends", 9},
        {3, "summer time starts", 8}
      ] do
    test "a host on Berlin time moves it across the weekend #{change}", ctx do
      Repo.update!(Changeset.change(ctx.profile, timezone: "Europe/Berlin"))
      sunday = last_sunday(Date.utc_today().year + 1, unquote(month))

      start =
        sunday
        |> Date.add(-1)
        |> DateTime.new!(~T[10:00:00], "Europe/Berlin")
        |> DateTime.shift_zone!("Etc/UTC")

      Repo.update!(
        Changeset.change(ctx.meeting,
          start_time: start,
          end_time: DateTime.add(start, 45, :minute)
        )
      )

      conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view
      |> element("[phx-click='show_reschedule_modal'][phx-value-id='#{ctx.meeting.id}']")
      |> render_click()

      monday = Date.add(sunday, 1)

      view
      |> form("[data-testid='host-move-form']", %{
        "move" => %{"start" => "#{Date.to_iso8601(monday)}T10:00"}
      })
      |> render_submit()

      moved = Repo.get!(MeetingSchema, ctx.meeting.id)
      assert moved.start_time == DateTime.new!(monday, Time.new!(unquote(monday_utc_hour), 0, 0))
      assert DateTime.diff(moved.end_time, moved.start_time, :minute) == 45
    end
  end

  test "the host cancels it from the dashboard and every guest is told", ctx do
    # A confirmed poll meeting has been announced; guests are only told of
    # the cancellation of a meeting that was.
    Repo.update!(Changeset.change(ctx.meeting, first_announced_at: DateTime.utc_now(:second)))

    conn = build_conn() |> init_test_session(%{}) |> fetch_session() |> log_in_user(ctx.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view |> element("#cancel-meeting-#{ctx.meeting.id}") |> render_click()
    view |> form("#cancel-meeting-form") |> render_submit()

    assert render(view) =~ "Meeting cancelled successfully"
    assert Repo.get!(MeetingSchema, ctx.meeting.id).status == :cancelled

    test_pid = self()

    expect(EmailServiceMock, :send_cancellation_email_to_organizer, fn email, details ->
      assert email == ctx.user.email
      assert details.host_managed
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_cancellation_email_to_attendee, 0, fn _email, _details ->
      {:ok, "sent"}
    end)

    expect(EmailServiceMock, :send_guest_cancellation, 2, fn email, _details ->
      send(test_pid, {:guest_told, email})
      {:ok, "sent"}
    end)

    assert [job] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_cancellation_emails", "meeting_id" => ctx.meeting.id}
             )

    assert :ok = perform_job(EmailWorker, job.args)
    assert_received {:guest_told, "ada@example.com"}
    assert_received {:guest_told, "bob@example.com"}
  end

  # The host's profile is on UTC here, so the input reads the same.
  defp local(datetime),
    do: datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  defp last_sunday(year, month) do
    last_day = Date.end_of_month(Date.new!(year, month, 1))
    Date.add(last_day, -rem(Date.day_of_week(last_day), 7))
  end
end
