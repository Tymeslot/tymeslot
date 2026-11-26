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
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.DashboardTestHelpers, only: [meetings_dashboard: 2, open_series_modal: 2]

  alias Ecto.Changeset
  alias Tymeslot.CalendarMock

  alias Tymeslot.MeetingPayments.BookingPayments
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

    %{
      payment: BookingPayments.payment_for_series(series.id),
      view: meetings_dashboard(conn, host.user)
    }
  end

  defp open_series(view) do
    first =
      Repo.one!(
        from(m in MeetingSchema,
          where: not is_nil(m.series_id),
          order_by: m.series_position,
          limit: 1
        )
      )

    open_series_modal(view, first)
  end

  defp record_refunds(payment, stripe_refunded_cents, lost_cents) do
    payment
    |> Changeset.change(
      stripe_refunded_cents: stripe_refunded_cents,
      disputed_lost_cents: lost_cents,
      refunded_amount_cents: min(stripe_refunded_cents + lost_cents, payment.amount_cents)
    )
    |> Repo.update!()
  end

  test "the series modal separates a lost dispute", %{view: view, payment: payment} do
    record_refunds(payment, 4_000, 6_000)
    open_series(view)

    assert has_element?(
             view,
             "[data-testid=series-payment]",
             "€40.00 refunded so far, plus €60.00 lost in a dispute"
           )
  end

  test "the series modal shows refunds a lost dispute over the same money repaid again", %{
    view: view,
    payment: payment
  } do
    assert payment.amount_cents == 20_000
    record_refunds(payment, 20_000, 20_000)
    open_series(view)

    assert has_element?(
             view,
             "[data-testid=series-payment]",
             "€200.00 refunded so far, plus €200.00 lost in a dispute"
           )
  end

  test "the series modal says when only a dispute took money back", %{
    view: view,
    payment: payment
  } do
    record_refunds(payment, 0, 6_000)
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
