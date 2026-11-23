defmodule TymeslotWeb.Dashboard.BookingsSeriesRefundTotalsTest do
  @moduledoc """
  What the series modal says was refunded on a paid series: the refunds
  made, with any amount a lost dispute took back shown apart from them.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :payments
  @moduletag :live
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    Paid.stub_charge_backfill()

    host = Paid.paid_host()
    Paid.expect_checkout()

    assert {:ok, :payment_required, %{series: series}} =
             Paid.book(host, Paid.paid_series_type(host), 4)

    event = Paid.completed_event("evt_PAID", series.id, 4 * Paid.price_cents())
    assert :ok = CheckoutSessionCompleted.handle(event)

    %{payment: MeetingPayments.payment_for_series(series.id), view: dashboard(conn, host)}
  end

  defp dashboard(conn, host) do
    host.user
    |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(host.user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view
  end

  defp open_series(view) do
    [first | _rest] =
      Repo.all(
        from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
      )

    view |> element("#view-series-#{first.id}") |> render_click()
    assert has_element?(view, "#series-modal [data-testid=series-modal]")
  end

  defp record_refunds(payment, refunded_cents, lost_cents) do
    payment
    |> Changeset.change(refunded_amount_cents: refunded_cents, disputed_lost_cents: lost_cents)
    |> Repo.update!()
  end

  test "the series modal separates a lost dispute", %{view: view, payment: payment} do
    record_refunds(payment, 10_000, 6_000)
    open_series(view)

    assert has_element?(
             view,
             "[data-testid=series-payment]",
             "€40.00 refunded so far, plus €60.00 lost in a dispute"
           )
  end

  test "the series modal says when only a dispute took money back", %{
    view: view,
    payment: payment
  } do
    record_refunds(payment, 6_000, 6_000)
    open_series(view)

    assert has_element?(view, "[data-testid=series-payment]", "€60.00 lost in a dispute")
    refute has_element?(view, "[data-testid=series-payment]", "refunded so far")
  end

  test "the series modal wording is unchanged without a dispute", %{
    view: view,
    payment: payment
  } do
    record_refunds(payment, 4_000, 0)
    open_series(view)

    assert has_element?(view, "[data-testid=series-payment]", "€40.00 refunded so far")
    refute has_element?(view, "[data-testid=series-payment]", "dispute")
  end
end
