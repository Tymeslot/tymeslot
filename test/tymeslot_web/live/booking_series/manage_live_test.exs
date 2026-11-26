defmodule TymeslotWeb.BookingSeries.ManageLiveTest do
  @moduledoc """
  The attendee's series page, `/:username/series/:series_uid`: every
  session of a booked series with how it stands and its own links, "Cancel
  all remaining sessions" behind a confirmation, a held request withdrawn
  whole, and the link resolved however it was addressed.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :scheduling
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.RateLimiterTestHelpers, only: [exhaust_limit!: 2]

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Phoenix.HTML
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.ThemeTestMatrix

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    :ok
  end

  defp host(username \\ "grace-host") do
    create_always_bookable_profile(
      timezone: "Etc/UTC",
      profile: %{username: username, full_name: "Grace Hopper"}
    )
  end

  defp series_type(host, attrs) do
    insert(
      :meeting_type,
      Keyword.merge(
        [
          user: host.user,
          name: "Mentoring",
          duration_minutes: 30,
          series_mode: :recurring,
          series_frequency: :weekly,
          series_interval: 1,
          series_min_occurrences: 2,
          series_max_occurrences: 12
        ],
        attrs
      )
    )
  end

  defp book(host, type, count) do
    BookingSeries.book(
      %{
        duration: 30,
        user_timezone: "Etc/UTC",
        organizer_user_id: host.user.id,
        meeting_type_id: type.id,
        series: %{mode: :recurring, first_start: Paid.at(7), count: count}
      },
      %{"name" => "Ada Lovelace", "email" => "ada@example.com", "message" => ""}
    )
  end

  defp book_series(attrs \\ [], count \\ 3) do
    host = host()
    assert {:ok, %{series: series}} = book(host, series_type(host, attrs), count)
    %{host: host, series: series}
  end

  defp page_path(series, username \\ "grace-host"), do: "/#{username}/series/#{series.uid}"

  defp meetings,
    do:
      Repo.all(
        from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
      )

  defp statuses, do: Enum.map(meetings(), & &1.status)

  defp session_statuses(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("[data-testid='series-session']")
    |> Enum.map(&(&1 |> Floki.attribute("data-status") |> hd()))
  end

  defp hrefs(view, selector) do
    view |> render() |> Floki.parse_document!() |> Floki.find(selector) |> Floki.attribute("href")
  end

  defp series_cancellation_jobs,
    do: all_enqueued(worker: EmailWorker, args: %{"action" => "send_series_cancellation"})

  describe "a one-to-one series" do
    setup do
      book_series()
    end

    test "lists every session with its own links", %{conn: conn, series: series} do
      {:ok, view, html} = live(conn, page_path(series))

      assert html =~ "Mentoring: 3 sessions with Grace Hopper"
      assert view |> element("[data-testid='series-rule']") |> render() =~ "Every week"
      assert session_statuses(view) == ["upcoming", "upcoming", "upcoming"]

      links = Enum.map(meetings(), &MeetingLinks.for_meeting/1)

      assert hrefs(view, "[data-testid='series-session-reschedule']") ==
               Enum.map(links, & &1.reschedule_url)

      assert hrefs(view, "[data-testid='series-session-cancel']") ==
               Enum.map(links, & &1.cancel_url)
    end

    test "cancel all remaining", %{conn: conn, series: series} do
      {:ok, view, _html} = live(conn, page_path(series))

      refute has_element?(view, "[data-testid='series-cancel-all-confirm']")
      view |> element("[data-testid='series-cancel-all']") |> render_click()

      assert view |> element("[data-testid='series-confirm']") |> render() =~
               "Cancel 3 upcoming sessions? This can&#39;t be undone."

      # Nothing is cancelled until the booker confirms.
      assert statuses() == [:confirmed, :confirmed, :confirmed]
      refute has_element?(view, "[data-testid='series-refund-warning']")

      view |> element("[data-testid='series-cancel-all-confirm']") |> render_click()

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert session_statuses(view) == ["cancelled", "cancelled", "cancelled"]
      assert hrefs(view, "[data-testid='series-session-cancel']") == []
      refute has_element?(view, "[data-testid='series-cancel-all']")
      assert has_element?(view, "[data-testid='series-nothing-left']")

      assert [%{args: %{"cancelled_by" => "attendee"}}] = series_cancellation_jobs()

      assert all_enqueued(worker: EmailWorker, args: %{"action" => "send_cancellation_emails"}) ==
               []
    end

    test "going back from the confirmation cancels nothing", %{conn: conn, series: series} do
      {:ok, view, _html} = live(conn, page_path(series))

      view |> element("[data-testid='series-cancel-all']") |> render_click()
      view |> element("[data-testid='series-keep']") |> render_click()

      refute has_element?(view, "[data-testid='series-confirm']")
      assert has_element?(view, "[data-testid='series-cancel-all']")
      assert statuses() == [:confirmed, :confirmed, :confirmed]
    end

    test "cancelling without the confirmation step does nothing", %{conn: conn, series: series} do
      {:ok, view, _html} = live(conn, page_path(series))

      render_click(view, "manage_series_cancel_all", %{})

      assert statuses() == [:confirmed, :confirmed, :confirmed]
      assert series_cancellation_jobs() == []
    end

    test "a partially cancelled series cancels only what is left", %{conn: conn, series: series} do
      [first, second, third] = meetings()
      assert {:ok, _result} = Meetings.cancel_meeting(second)

      {:ok, view, _html} = live(conn, page_path(series))

      assert session_statuses(view) == ["upcoming", "cancelled", "upcoming"]
      refute has_element?(view, "#series-session-2 a")

      view |> element("[data-testid='series-cancel-all']") |> render_click()

      assert view |> element("[data-testid='series-confirm']") |> render() =~
               "Cancel 2 upcoming sessions?"

      view |> element("[data-testid='series-cancel-all-confirm']") |> render_click()

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert [%{args: args}] = series_cancellation_jobs()
      assert Enum.sort(args["occurrence_ids"]) == Enum.sort([first.id, third.id])
    end

    test "a session held for approval on its own counts, and has its own cancel link", %{
      conn: conn,
      series: series
    } do
      [_first, held, _third] = meetings()

      # Moved back into the gate by a reschedule on an approval type: a
      # request of its own, not the series'.
      held
      |> Changeset.change(
        status: :awaiting_approval,
        approval_requested_at: DateTime.utc_now(:second),
        approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 48, :hour)
      )
      |> Repo.update!()

      {:ok, view, _html} = live(conn, page_path(series))

      assert session_statuses(view) == ["upcoming", "awaiting_approval", "upcoming"]
      refute has_element?(view, "[data-testid='series-withdraw']")

      assert hrefs(view, "#series-session-2 [data-testid='series-session-cancel']") ==
               [MeetingLinks.for_meeting(held).cancel_url]

      refute has_element?(view, "#series-session-2 [data-testid='series-session-reschedule']")

      view |> element("[data-testid='series-cancel-all']") |> render_click()

      assert view |> element("[data-testid='series-confirm']") |> render() =~
               "Cancel 3 upcoming sessions?"

      view |> element("[data-testid='series-cancel-all-confirm']") |> render_click()

      assert statuses() == [:cancelled, :cancelled, :cancelled]
    end

    test "a moved session drops the day and time from the rhythm", %{conn: conn, series: series} do
      {:ok, view, _html} = live(conn, page_path(series))
      assert view |> element("[data-testid='series-rule']") |> render() =~ " at "

      [first | _rest] = meetings()
      start = DateTime.add(first.start_time, 2, :hour)

      first
      |> Changeset.change(start_time: start, end_time: DateTime.add(start, 30, :minute))
      |> Repo.update!()

      {:ok, view, _html} = live(conn, page_path(series))
      rule = view |> element("[data-testid='series-rule']") |> render()

      assert rule =~ "Every week"
      refute rule =~ " at "
    end

    test "the confirmation takes the focus, and going back returns it", %{
      conn: conn,
      series: series
    } do
      {:ok, view, _html} = live(conn, page_path(series))

      # Nothing takes the focus on load.
      refute has_element?(view, "[data-testid='series-cancel-all'][phx-mounted]")

      view |> element("[data-testid='series-cancel-all']") |> render_click()
      assert has_element?(view, "[data-testid='series-keep'][phx-mounted*='focus']")

      view |> element("[data-testid='series-keep']") |> render_click()
      assert has_element?(view, "[data-testid='series-cancel-all'][phx-mounted*='focus']")
    end

    test "each session's links name the session for a screen reader", %{
      conn: conn,
      series: series
    } do
      {:ok, view, _html} = live(conn, page_path(series))

      assert view
             |> element("#series-session-2 [data-testid='series-session-cancel'] .sr-only")
             |> render() =~ "session 2,"
    end

    test "a past session has no links", %{conn: conn, series: series} do
      [first | _rest] = meetings()
      start = DateTime.add(DateTime.utc_now(:second), -7, :day)

      first
      |> Changeset.change(start_time: start, end_time: DateTime.add(start, 30, :minute))
      |> Repo.update!()

      {:ok, view, _html} = live(conn, page_path(series))

      assert session_statuses(view) == ["past", "upcoming", "upcoming"]
      refute has_element?(view, "#series-session-1 a")
      assert has_element?(view, "#series-session-2 [data-testid='series-session-cancel']")

      view |> element("[data-testid='series-cancel-all']") |> render_click()

      assert view |> element("[data-testid='series-confirm']") |> render() =~
               "Cancel 2 upcoming sessions?"
    end

    test "the page renders in every shipped theme", %{conn: conn, series: series} do
      for theme_id <- ThemeTestMatrix.ids() do
        {:ok, view, _html} = live(conn, page_path(series) <> "?theme=#{theme_id}")

        assert has_element?(view, ".booker-card [data-testid='series-page-title']"),
               "theme #{theme_id} draws no series page"

        assert length(session_statuses(view)) == 3
      end
    end

    @tag :capture_log
    test "the cancel-all is rate limited as a meeting's cancel is", %{conn: conn, series: series} do
      conn = %{conn | remote_ip: {203, 0, 113, 77}}
      {:ok, view, _html} = live(conn, page_path(series))

      client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip] || "unknown"
      refusal = exhaust_limit!(:meeting_cancel, client_ip)

      view |> element("[data-testid='series-cancel-all']") |> render_click()
      view |> element("[data-testid='series-cancel-all-confirm']") |> render_click()

      assert render(view) =~ refusal |> HTML.html_escape() |> HTML.safe_to_string()
      assert statuses() == [:confirmed, :confirmed, :confirmed]
      assert series_cancellation_jobs() == []
    end
  end

  test "a group series links to seat pages", %{conn: conn} do
    %{series: series} = book_series(max_participants: 3)

    seats =
      Repo.all(
        from(p in ParticipantSchema,
          where: p.series_id == ^series.id,
          order_by: p.series_position
        )
      )

    assert length(seats) == 3

    {:ok, view, _html} = live(conn, page_path(series))

    assert session_statuses(view) == ["upcoming", "upcoming", "upcoming"]

    base = Endpoint.url()

    assert hrefs(view, "[data-testid='series-session-reschedule']") ==
             Enum.map(seats, &"#{base}/seat/#{&1.management_token}/reschedule")

    assert hrefs(view, "[data-testid='series-session-cancel']") ==
             Enum.map(seats, &"#{base}/seat/#{&1.management_token}/cancel")
  end

  describe "a paid series" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      Paid.stub_charge_backfill()

      host = Paid.paid_host()
      Paid.expect_checkout()

      assert {:ok, :payment_required, %{series: series}} =
               Paid.book(host, Paid.paid_series_type(host), 3)

      %{series: series}
    end

    test "a series awaiting payment offers no cancel-all", %{conn: conn, series: series} do
      {:ok, view, _html} = live(conn, page_path(series))

      assert session_statuses(view) == [
               "awaiting_payment",
               "awaiting_payment",
               "awaiting_payment"
             ]

      refute has_element?(view, "[data-testid='series-cancel-all']")
      assert hrefs(view, "[data-testid='series-session-cancel']") == []
    end

    test "a paid series warns that no refund is automatic", %{conn: conn, series: series} do
      event = Paid.completed_event("evt_PAID", series.id, 3 * Paid.price_cents())
      assert :ok = CheckoutSessionCompleted.handle(event)

      {:ok, view, _html} = live(conn, page_path(series))
      view |> element("[data-testid='series-cancel-all']") |> render_click()

      assert view |> element("[data-testid='series-refund-warning']") |> render() =~
               "Cancelling doesn&#39;t refund your payment automatically. Contact Grace Hopper about a refund."
    end
  end

  test "an approval request can be withdrawn", %{conn: conn} do
    %{series: series} = book_series(requires_approval: true, approval_window_hours: 48)
    assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]

    {:ok, view, _html} = live(conn, page_path(series))

    assert session_statuses(view) == [
             "awaiting_approval",
             "awaiting_approval",
             "awaiting_approval"
           ]

    refute has_element?(view, "[data-testid='series-cancel-all']")
    assert hrefs(view, "[data-testid='series-session-cancel']") == []

    view |> element("[data-testid='series-withdraw']") |> render_click()

    assert view |> element("[data-testid='series-confirm']") |> render() =~
             "Withdraw your request for 3 sessions?"

    view |> element("[data-testid='series-withdraw-confirm']") |> render_click()

    assert statuses() == [:cancelled, :cancelled, :cancelled]
    assert session_statuses(view) == ["cancelled", "cancelled", "cancelled"]
    refute has_element?(view, "[data-testid='series-withdraw']")
    assert [%{args: %{"cancelled_by" => "attendee"}}] = series_cancellation_jobs()
  end

  describe "a series held for approval" do
    setup do
      book_series(requires_approval: true, approval_window_hours: 48)
    end

    test "withdrawing without the confirmation step does nothing", %{conn: conn, series: series} do
      {:ok, view, _html} = live(conn, page_path(series))

      render_click(view, "manage_series_withdraw", %{})

      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]
      assert series_cancellation_jobs() == []
    end

    @tag :capture_log
    test "the withdrawal is rate limited", %{conn: conn, series: series} do
      conn = %{conn | remote_ip: {203, 0, 113, 78}}
      {:ok, view, _html} = live(conn, page_path(series))

      client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip] || "unknown"
      refusal = exhaust_limit!(:meeting_cancel, client_ip)

      view |> element("[data-testid='series-withdraw']") |> render_click()
      view |> element("[data-testid='series-withdraw-confirm']") |> render_click()

      assert render(view) =~ refusal |> HTML.html_escape() |> HTML.safe_to_string()
      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]
    end

    test "a withdrawal the host answered first cancels nothing and says so", %{
      conn: conn,
      series: series,
      host: host
    } do
      {:ok, view, _html} = live(conn, page_path(series))
      view |> element("[data-testid='series-withdraw']") |> render_click()

      # The host approves while the confirmation is open.
      assert {:ok, _approved} = SeriesApproval.approve(series, host.user)

      html = view |> element("[data-testid='series-withdraw-confirm']") |> render_click()

      assert html =~ "The host answered your request in the meantime"
      assert statuses() == [:confirmed, :confirmed, :confirmed]
      assert session_statuses(view) == ["upcoming", "upcoming", "upcoming"]
      assert series_cancellation_jobs() == []
    end

    test "a request with one session moved is cancelled whole, not withdrawn", %{
      conn: conn,
      series: series
    } do
      [_first, moved, _third] = meetings()

      moved
      |> Changeset.change(approval_requested_at: DateTime.add(moved.approval_requested_at, 60))
      |> Repo.update!()

      {:ok, view, _html} = live(conn, page_path(series))

      refute has_element?(view, "[data-testid='series-withdraw']")
      assert length(hrefs(view, "[data-testid='series-session-cancel']")) == 3

      view |> element("[data-testid='series-cancel-all']") |> render_click()

      assert view |> element("[data-testid='series-confirm']") |> render() =~
               "Cancel 3 upcoming sessions?"

      view |> element("[data-testid='series-cancel-all-confirm']") |> render_click()

      assert statuses() == [:cancelled, :cancelled, :cancelled]
    end
  end

  describe "finding the series" do
    test "an unknown series is not found", %{conn: conn} do
      host()

      for uid <- [UUID.generate(), "not-a-uuid"] do
        assert {:error, {:redirect, %{to: "/grace-host", flash: %{"error" => message}}}} =
                 live(conn, "/grace-host/series/#{uid}")

        assert message =~ "This series could not be found"
      end
    end

    test "the uid-only link redirects to the current username", %{conn: conn} do
      %{host: host, series: series} = book_series()

      assert redirected_to(get(conn, "/series/#{series.uid}")) == page_path(series)

      {:ok, _profile} = Profiles.change_username(host.profile, "grace-renamed")

      assert redirected_to(get(build_conn(), "/series/#{series.uid}")) ==
               page_path(series, "grace-renamed")
    end

    test "no host can take the uid-only links' username" do
      %{host: host} = book_series()

      assert {:error, "This username is reserved"} =
               Profiles.change_username(host.profile, "series")
    end

    test "the uid-only link to an unknown series is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, "/series/#{UUID.generate()}") end
    end

    test "an old username redirects to the current one", %{conn: conn} do
      %{host: host, series: series} = book_series()
      {:ok, _profile} = Profiles.change_username(host.profile, "grace-renamed")

      assert {:error, {:redirect, %{to: to}}} = live(conn, page_path(series))
      assert to == page_path(series, "grace-renamed")
    end

    test "another host's username with a correct uid", %{conn: conn} do
      %{series: series} = book_series()
      host("someone-else")

      # The series is shown only under its own host's page.
      assert {:error, {:redirect, %{to: to}}} = live(conn, page_path(series, "someone-else"))
      assert to == page_path(series)
    end
  end
end
