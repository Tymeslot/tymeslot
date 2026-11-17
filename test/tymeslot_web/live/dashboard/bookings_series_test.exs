defmodule TymeslotWeb.Dashboard.BookingsSeriesTest do
  @moduledoc """
  A booked series on the host's Meetings page: each session's card says
  which session of the series it is and opens the series, the series modal
  lists every session, and "Cancel remaining sessions" cancels the rest
  with one email and, for a paid series, the remaining sessions' refund. A
  series request is answered whole from any of its cards, and on the
  emailed review page, which lists every session.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :live
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.SeriesHostRefund
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.ApprovalToken
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    :ok
  end

  defp host do
    create_always_bookable_profile(
      timezone: "Etc/UTC",
      profile: %{username: "grace-host", full_name: "Grace Hopper"}
    )
  end

  defp series_type(host, attrs \\ []) do
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

  defp meetings,
    do:
      Repo.all(
        from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
      )

  defp statuses, do: Enum.map(meetings(), & &1.status)

  defp dashboard(conn, host) do
    host.user
    |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(host.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view
  end

  defp open_series(view, meeting) do
    view |> element("#view-series-#{meeting.id}") |> render_click()
    assert has_element?(view, "#series-modal [data-testid=series-modal]")
    view
  end

  defp confirm_cancel_remaining(view, params \\ %{}) do
    view |> element("[data-testid=cancel-remaining-sessions]") |> render_click()
    view |> form("#cancel-series-form", params) |> render_submit()
  end

  describe "a one-to-one series" do
    setup %{conn: conn} do
      host = host()
      assert {:ok, %{series: series}} = book(host, series_type(host), 4)
      %{host: host, series: series, view: dashboard(conn, host)}
    end

    test "a series member shows its position", %{view: view} do
      [_first, second | _rest] = meetings()

      assert has_element?(
               view,
               "#meetings-#{second.id} [data-testid=series-badge]",
               "Session 2 of 4"
             )

      assert has_element?(view, "#view-series-#{second.id}")
    end

    test "the series modal lists every session", %{view: view, host: host} do
      [first | _rest] = sessions = meetings()
      open_series(view, first)

      assert has_element?(view, "#series-modal", "Series with Ada Lovelace")
      assert has_element?(view, "#series-modal", "Every week on")

      for session <- sessions do
        assert has_element?(
                 view,
                 "#series-session-#{session.id}",
                 "Session #{session.series_position} of 4"
               )
      end

      assert has_element?(view, "#series-session-#{first.id} [data-testid=series-session-cancel]")

      # Each session's actions say which session they act on.
      assert has_element?(
               view,
               "#series-session-#{first.id} button[aria-label^='Cancel session 1, ']"
             )

      assert has_element?(
               view,
               "#series-session-#{first.id} button[aria-label^='Reschedule session 1, ']"
             )

      refute has_element?(view, "[data-testid=series-payment]")
      assert host.user.id == first.organizer_user_id
    end

    test "cancel remaining from the dashboard", %{view: view, series: series} do
      [first | _rest] = meetings()
      open_series(view, first)

      confirm_cancel_remaining(view)
      html = render(view)

      assert statuses() == [:cancelled, :cancelled, :cancelled, :cancelled]
      assert Repo.reload!(series).cancelled_at

      assert [%{args: %{"cancelled_by" => "organizer", "occurrence_ids" => ids}}] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_series_cancellation"})

      assert length(ids) == 4
      assert html =~ "4 sessions cancelled"

      # The upcoming list was redrawn: no card of the series is left on it.
      refute has_element?(view, "[data-testid=series-badge]")
      refute has_element?(view, "#cancel-series-modal #cancel-series-form")
    end

    test "the cancel confirmation counts only the sessions still to come", %{view: view} do
      [first | _rest] = meetings()

      first
      |> Changeset.change(status: :cancelled, cancelled_at: DateTime.utc_now(:second))
      |> Repo.update!()

      [_cancelled, second | _rest] = meetings()
      open_series(view, second)
      view |> element("[data-testid=cancel-remaining-sessions]") |> render_click()

      assert has_element?(
               view,
               "#cancel-series-form",
               "Cancel 3 upcoming sessions with Ada Lovelace?"
             )
    end

    test "another host's series cannot be opened", %{view: view} do
      other = insert(:booking_series, organizer_user: insert(:user))

      view
      |> with_target("#bookings-management")
      |> render_click("series:show", %{"series" => other.id})

      refute has_element?(view, "#series-modal [data-testid=series-modal]")
    end
  end

  describe "a paid series" do
    setup %{conn: conn} do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_SERIES", _opts ->
        {:ok, %{"latest_charge" => "ch_SERIES"}}
      end)

      host = Paid.paid_host()
      Paid.expect_checkout()

      assert {:ok, :payment_required, %{series: series}} =
               Paid.book(host, Paid.paid_series_type(host), 4)

      event = Paid.completed_event("evt_PAID", series.id, 4 * Paid.price_cents())
      assert :ok = CheckoutSessionCompleted.handle(event)

      %{
        host: host,
        series: series,
        payment: MeetingPayments.payment_for_series(series.id),
        view: dashboard(conn, host)
      }
    end

    defp expect_refund(amount) do
      expect(StripeAdapterMock, :create_refund, 1, fn params, _opts ->
        assert params.charge == "ch_SERIES"
        assert params.amount == amount
        {:ok, %{id: "re_SERIES_#{System.unique_integer([:positive])}"}}
      end)
    end

    test "cancel remaining on a paid series refunds the remaining share by default", %{
      view: view,
      payment: payment
    } do
      [first | _rest] = meetings()
      open_series(view, first)

      assert has_element?(view, "[data-testid=series-payment]", "€200.00 paid")
      assert has_element?(view, "[data-testid=series-payment]", "€0.00 refunded so far")

      view |> element("[data-testid=cancel-remaining-sessions]") |> render_click()

      assert has_element?(
               view,
               "#cancel-series-form",
               "Refund the remaining sessions (€200.00)."
             )

      view |> form("#cancel-series-form") |> render_submit()
      html = render(view)

      assert statuses() == [:cancelled, :cancelled, :cancelled, :cancelled]
      assert html =~ "Refund of €200.00 is being processed. We&#39;ll email you if it fails."

      expect_refund(20_000)
      assert [%{args: args}] = all_enqueued(worker: SeriesHostRefund)
      assert :ok = perform_job(SeriesHostRefund, args)

      assert %{refunded_amount_cents: 20_000, status: :refunded} = Repo.reload!(payment)
    end

    test "a partial refund on cancel remaining refunds that amount", %{
      view: view,
      payment: payment
    } do
      [first | _rest] = meetings()
      open_series(view, first)

      confirm_cancel_remaining(view, %{
        "cancel_refund_choice" => "partial",
        "cancel_refund_amount" => "30.00"
      })

      expect_refund(3_000)
      assert [%{args: args}] = all_enqueued(worker: SeriesHostRefund)
      assert :ok = perform_job(SeriesHostRefund, args)
      assert Repo.reload!(payment).refunded_amount_cents == 3_000
    end

    test "past the refund window, cancel remaining says no refund was made", %{
      view: view,
      payment: payment
    } do
      payment
      |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day))
      |> Repo.update!()

      [first | _rest] = meetings()
      open_series(view, first)
      view |> element("[data-testid=cancel-remaining-sessions]") |> render_click()

      # Nothing can be refunded, so there is nothing to choose, and the
      # dialog says why before the host confirms.
      refute has_element?(view, "#cancel-series-form input[name=cancel_refund_choice]")

      assert has_element?(
               view,
               "#cancel-series-form",
               "Cancelling won't refund the attendee: the payment is older than the 60-day refund window."
             )

      view |> form("#cancel-series-form") |> render_submit()

      assert statuses() == [:cancelled, :cancelled, :cancelled, :cancelled]
      assert all_enqueued(worker: SeriesHostRefund) == []

      assert render(view) =~
               "4 sessions cancelled without a refund: the payment is older than the 60-day refund window."
    end

    test "a disputed payment is said up front to be refunded by none of it", %{
      view: view,
      payment: payment
    } do
      payment |> Changeset.change(status: :disputed) |> Repo.update!()

      [first | _rest] = meetings()
      open_series(view, first)
      view |> element("[data-testid=cancel-remaining-sessions]") |> render_click()

      assert has_element?(
               view,
               "#cancel-series-form",
               "Cancelling won't refund the attendee: the payment is under dispute."
             )
    end

    test "a refundable payment carries no no-refund warning", %{view: view} do
      [first | _rest] = meetings()
      open_series(view, first)
      view |> element("[data-testid=cancel-remaining-sessions]") |> render_click()

      assert has_element?(view, "#cancel-series-form input[name=cancel_refund_choice]")
      refute has_element?(view, "#cancel-series-form", "Cancelling won't refund the attendee")
    end

    test "a refused amount keeps the dialog open with nothing cancelled", %{view: view} do
      [first | _rest] = meetings()
      open_series(view, first)

      confirm_cancel_remaining(view, %{
        "cancel_refund_choice" => "partial",
        "cancel_refund_amount" => "999.00"
      })

      assert has_element?(view, "input[name=cancel_refund_choice][value=partial][checked]")
      assert has_element?(view, "#cancel-series-form [role=alert]", "exceeds the remaining")
      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert all_enqueued(worker: SeriesHostRefund) == []
    end

    test "cancelling one paid session defaults to one session's refund", %{
      view: view,
      payment: payment
    } do
      [_first, second | _rest] = meetings()

      view |> element("#cancel-meeting-#{second.id}") |> render_click()

      assert has_element?(
               view,
               "#cancel-meeting-form",
               "Refunds one session's share of the series payment (€50.00)."
             )

      expect_refund(5_000)
      view |> form("#cancel-meeting-form") |> render_submit()

      assert statuses() == [:confirmed, :cancelled, :confirmed, :confirmed]
      assert Repo.reload!(payment).refunded_amount_cents == 5_000
    end
  end

  describe "a series request" do
    setup %{conn: conn} do
      host = host()
      type = series_type(host, requires_approval: true, approval_window_hours: 48)
      assert {:ok, %{series: series}} = book(host, type, 3)
      %{host: host, series: series, conn: conn}
    end

    defp open_requests(conn, host) do
      view = dashboard(conn, host)
      render_click(element(view, "button", "Requests"))
      view
    end

    test "every card of the request lists its sessions and answers for all", %{
      conn: conn,
      host: host
    } do
      view = open_requests(conn, host)
      [first, second, third] = meetings()

      for session <- [first, second, third] do
        assert has_element?(view, "#approve-request-#{session.id}", "Approve all 3")

        assert has_element?(
                 view,
                 "#meetings-#{session.id} [data-testid=series-request-sessions]",
                 "Part of a request for 3 sessions"
               )
      end
    end

    test "approving a series request confirms every session", %{conn: conn, host: host} do
      view = open_requests(conn, host)
      [_first, second, _third] = meetings()

      view |> element("#approve-request-#{second.id}") |> render_click()
      render_async(view)

      assert statuses() == [:confirmed, :confirmed, :confirmed]
      # The flash reaches the parent LiveView via `send/2`, a round trip of
      # its own after the answer's result.
      assert render(view) =~ "All 3 sessions confirmed."
    end

    test "declining from one card declines the whole series", %{conn: conn, host: host} do
      view = open_requests(conn, host)
      [first, _second, _third] = meetings()

      view |> element("#meetings-#{first.id} [data-testid=decline-request]") |> render_click()

      assert has_element?(
               view,
               "#decline-request-form",
               "Decline the request from Ada Lovelace for all 3 sessions?"
             )

      view |> form("#decline-request-form", %{"reason" => ""}) |> render_submit()
      render_async(view)

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert render(view) =~ "Request declined. All 3 sessions are free again."
    end

    test "the Requests tab counts a series request once", %{conn: conn, host: host} do
      start = DateTime.add(DateTime.utc_now(:second), 3, :day)

      insert(:meeting,
        organizer_user_id: host.user.id,
        organizer_email: host.user.email,
        status: :awaiting_approval,
        start_time: start,
        end_time: DateTime.add(start, 30, :minute),
        approval_requested_at: DateTime.utc_now(:second),
        approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
      )

      assert Meetings.count_awaiting_approval_for_organizer(host.user.id) == 2

      view = dashboard(conn, host)
      assert view |> element("#meetings-filter button", "Requests") |> render() =~ ~r/>\s*2\s*</
    end

    test "the review page lists every session and answers all of them", %{conn: conn} do
      [first, _second, _third] = meetings()
      {:ok, view, _html} = live(conn, "/meeting-request/" <> ApprovalToken.sign(first))

      for session <- meetings() do
        assert has_element?(view, "#request-session-#{session.id}")
      end

      assert has_element?(view, "[data-testid=approve-request]", "Approve all 3 sessions")

      html = view |> element("[data-testid=approve-request]") |> render_click()

      assert statuses() == [:confirmed, :confirmed, :confirmed]
      assert html =~ "has been sent the confirmation for all 3 sessions."
    end

    test "the review page declines all of them", %{conn: conn} do
      [first, _second, _third] = meetings()
      {:ok, view, _html} = live(conn, "/meeting-request/" <> ApprovalToken.sign(first))

      view |> element("button[phx-value-intent=decline]") |> render_click()
      assert has_element?(view, "[data-testid=decline-request]", "Decline all 3 sessions")

      html = view |> form("#decline-request-form", %{"reason" => ""}) |> render_submit()

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert html =~ "All 3 sessions are free again and Ada Lovelace has been told."
    end

    test "the review page keeps speaking of every session once answered", %{
      conn: conn,
      host: host,
      series: series
    } do
      [first, _second, _third] = meetings()
      token = ApprovalToken.sign(first)
      assert {:ok, _sessions} = SeriesApproval.approve(series, host.user)

      {:ok, view, _html} = live(conn, "/meeting-request/" <> token)

      assert render(view) =~ "has been sent the confirmation for all 3 sessions."
    end
  end

  describe "a group series" do
    setup %{conn: conn} do
      host = host()
      type = series_type(host, max_participants: 3)
      assert {:ok, %{series: series}} = book(host, type, 3)
      %{host: host, series: series, view: dashboard(conn, host)}
    end

    defp seats,
      do:
        Repo.all(
          from(p in ParticipantSchema,
            where: not is_nil(p.series_id),
            order_by: p.series_position
          )
        )

    test "the series opens from the booker's seat and cancels its remaining seats", %{
      view: view,
      series: series
    } do
      [first_seat | _rest] = seats = seats()

      # The shared session's card is no session of the series itself.
      refute has_element?(view, "[data-testid=series-badge]")

      view |> element("#view-series-seat-#{first_seat.id}") |> render_click()
      assert has_element?(view, "#series-modal", "Series with Ada Lovelace")

      for seat <- seats do
        assert has_element?(
                 view,
                 "#series-session-#{seat.meeting_id}",
                 "Session #{seat.series_position} of 3"
               )
      end

      # A seat's session is shared: its own actions would act on everyone.
      refute has_element?(view, "[data-testid=series-session-cancel]")

      confirm_cancel_remaining(view)

      assert Enum.all?(seats(), &(not ParticipantSchema.live?(&1)))
      assert Repo.reload!(series).cancelled_at

      assert [%{args: %{"cancelled_by" => "organizer"}}] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_series_cancellation"})

      assert render(view) =~ "3 sessions cancelled"
    end
  end

  test "a page of series members loads their series in one query" do
    user = insert(:user)

    for n <- 1..10 do
      series = insert(:booking_series, organizer_user: user)

      for position <- 1..2 do
        start = DateTime.add(DateTime.utc_now(:second), n * 24 + position, :hour)

        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          series_id: series.id,
          series_position: position,
          start_time: start,
          end_time: DateTime.add(start, 30, :minute)
        )
      end
    end

    test_pid = self()
    handler_id = "series-query-count-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        # Preloads run in their own processes; this module runs alone.
        send(test_pid, {:query, source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{items: items}} =
             Meetings.list_user_meetings_by_filter(user.id, "upcoming", per_page: 20)

    assert length(items) == 20
    assert Enum.all?(items, &match?({_position, 2}, BookingSeries.place(&1)))

    assert_received {:query, "booking_series"}
    refute_received {:query, "booking_series"}
  end
end
