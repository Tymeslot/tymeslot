defmodule TymeslotWeb.Dashboard.CalendarGrid.EventCreationRateLimitTest do
  @moduledoc """
  Rate limiting of the calendar grid's create paths. Quick add in meeting
  mode emails the main guest and every extra guest on each save, so it has
  its own budget; a plain event create is a provider write and spends the
  edit budget. Runs with `async: false` because rate-limit state lives in a
  shared ETS table.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :security

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  test "rate limiter rejects event edits after bucket is exhausted", %{user: user} do
    # Exhaust the per-user edit limit (30 per 5 minutes)
    for _i <- 1..30 do
      assert :ok = RateLimiter.check_calendar_event_edit_rate_limit(user.id)
    end

    # The next call must be rejected
    assert {:error, :rate_limited, message} =
             RateLimiter.check_calendar_event_edit_rate_limit(user.id)

    assert message =~ "reached the limit"
  end

  describe "quick add in meeting mode" do
    test "a save past the limit is refused and emails no one", %{conn: conn, user: user} do
      spend_quick_add_meetings(user.id, 20)
      lv = open_meeting_form(conn)

      html = save(lv)

      assert html =~ "Too many new meetings. Please wait a moment."
      refute html =~ "Creating..."
      # The modal stays open so the organiser can retry once the window passes.
      assert html =~ ~s(id="create-event-modal")
      assert Repo.aggregate(MeetingSchema, :count) == 0
      refute_enqueued(worker: EmailWorker)
    end

    test "the last save within the limit books the meeting and emails the guest",
         %{conn: conn, user: user} do
      spend_quick_add_meetings(user.id, 19)
      lv = open_meeting_form(conn)

      html = save(lv)

      refute html =~ "Too many new meetings"
      meeting = eventually(fn -> Repo.one(MeetingSchema) end, timeout: 5000)
      assert meeting.attendee_email == "ada@example.com"

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_confirmation_emails", "meeting_id" => meeting.id}
      )
    end

    test "does not share a budget with inviting guests to a booking", %{user: user} do
      for _i <- 1..20, do: RateLimiter.check_dashboard_add_guests_rate_limit(user.id)

      assert :ok = RateLimiter.check_dashboard_quick_add_meeting_rate_limit(user.id)
    end
  end

  describe "quick add of a plain event" do
    test "a save past the edit limit is refused", %{conn: conn, user: user} do
      insert(:calendar_integration, user: user, is_active: true)
      for _i <- 1..30, do: RateLimiter.check_calendar_event_edit_rate_limit(user.id)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-grid-header button[phx-click='show_create_form']", "Quick add")
      |> render_click()

      lv |> element("button[phx-click='save_event']") |> render_click()
      html = render(lv)

      assert html =~ "Too many edits. Please wait a moment."
      refute html =~ "Creating..."
    end
  end

  defp spend_quick_add_meetings(user_id, count) do
    for _i <- 1..count do
      assert :ok = RateLimiter.check_dashboard_quick_add_meeting_rate_limit(user_id)
    end
  end

  defp open_meeting_form(conn) do
    {:ok, lv, _html} = live(conn, ~p"/dashboard")

    lv |> element("#calendar-grid") |> render_hook("show_create_form", %{})
    hook(lv, "update_create_guest_name", %{"value" => "Ada Lovelace"})
    hook(lv, "update_create_guest_email", %{"value" => "ada@example.com"})

    lv
  end

  defp save(lv) do
    hook(lv, "save_event", %{})
    # The refusal flash travels through the parent LiveView's handle_info.
    render(lv)
  end

  defp hook(lv, event, params),
    do: lv |> element("#calendar-grid") |> render_hook(event, params)
end
