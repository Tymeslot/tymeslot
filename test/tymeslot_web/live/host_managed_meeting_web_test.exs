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
        status: "confirmed",
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
      status: "confirmed",
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

    Repo.update!(Changeset.change(ctx.meeting, status: "cancelled"))

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

  # The host's profile is on UTC here, so the input reads the same.
  defp local(datetime),
    do: datetime |> DateTime.to_naive() |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
end
