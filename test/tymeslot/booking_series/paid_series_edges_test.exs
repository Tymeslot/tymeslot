defmodule Tymeslot.BookingSeries.PaidSeriesEdgesTest do
  @moduledoc """
  The ways a paid series can leave the straight path: a held session
  someone tries to cancel alone, a payment that arrives for a series that
  cannot go ahead whole, a series gone or refused, a dispute, a checkout
  abandoned, and the balances the host is shown while some sessions still
  go ahead.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.PaidSeriesTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.CalendarMock
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Emails.Templates.AppointmentCancellation.RefundNotice
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.ApprovalRefunds
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SeriesAnnouncementWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_SERIES", _opts ->
      {:ok, %{"latest_charge" => "ch_SERIES"}}
    end)

    host = paid_host()
    expect_checkout()
    assert {:ok, :payment_required, %{series: series}} = book(host, paid_series_type(host), 3)

    %{host: host, series: series, payment: MeetingPayments.payment_for_series(series.id)}
  end

  defp meetings,
    do:
      Repo.all(
        from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
      )

  defp statuses, do: Enum.map(meetings(), & &1.status)
  defp total, do: 3 * price_cents()

  defp set_status(meeting, status),
    do: meeting |> Changeset.change(status: status) |> Repo.update!()

  defp pay(series),
    do:
      assert(
        :ok = CheckoutSessionCompleted.handle(completed_event("evt_PAID", series.id, total()))
      )

  defp lapse(series),
    do: assert(:ok = CheckoutSessionExpired.handle(expired_event("evt_EXPIRED", series.id)))

  defp outstanding(host), do: MeetingPayments.list_outstanding_refunds_for_host(host.user.id)

  describe "a session held for the series' payment" do
    test "cannot be cancelled alone by the host", %{host: host} do
      [_first, second, _third] = meetings()

      assert {:error, {:not_cancellable, :held_for_series_payment}} =
               Meetings.cancel_meeting_with_refund(second, host.user.id, :none)

      assert statuses() == [:awaiting_payment, :awaiting_payment, :awaiting_payment]
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_cancellation_emails"})
    end

    test "cannot be cancelled alone by the attendee" do
      [first | _rest] = meetings()

      assert {:error, {:not_cancellable, :held_for_series_payment}} =
               Meetings.cancel_meeting(first)

      assert statuses() == [:awaiting_payment, :awaiting_payment, :awaiting_payment]
      refute_enqueued(worker: EmailWorker, args: %{"action" => "send_cancellation_emails"})
    end
  end

  test "a payment for a series some of whose sessions were released is refunded", %{
    series: series,
    payment: payment
  } do
    [first, second, _third] = meetings()
    set_status(second, :cancelled)
    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, MeetingPayments.payment_topic(first.id))

    pay(series)

    assert statuses() == [:expired, :cancelled, :expired]
    assert Repo.reload!(payment).status == :paid
    assert_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: payment.id})
    assert_received :expired
    refute_enqueued(worker: SeriesAnnouncementWorker)
    assert all_enqueued(worker: CalendarEventWorker, args: %{"action" => "create"}) == []
  end

  test "a payment for a host awaiting deletion is refused and refunded", %{
    host: host,
    series: series,
    payment: payment
  } do
    host.user
    |> Changeset.change(deletion_scheduled_at: DateTime.utc_now(:second))
    |> Repo.update!()

    pay(series)

    assert statuses() == [:expired, :expired, :expired]
    assert Repo.reload!(payment).status == :paid
    assert_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: payment.id})
  end

  test "a payment for a series with no session left is refunded", %{
    series: series,
    payment: payment
  } do
    Repo.delete_all(from(m in MeetingSchema, where: m.series_id == ^series.id))

    pay(series)

    assert Repo.reload!(payment).status == :paid
    assert_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: payment.id})
  end

  test "a dispute won on a series that never went ahead refunds what is left", %{
    series: series,
    payment: payment
  } do
    lapse(series)

    payment
    |> Repo.reload!()
    |> Changeset.change(
      status: :disputed,
      stripe_charge_id: "ch_SERIES",
      paid_at: DateTime.utc_now(:second)
    )
    |> Repo.update!()

    assert :ok = ChargeDisputeClosed.handle(dispute_closed("won"))

    assert_enqueued(
      worker: RefundLatePayment,
      args: %{booking_payment_id: payment.id, reason: "after_dispute"}
    )
  end

  test "a dispute won on a series still going ahead refunds nothing", %{
    series: series,
    payment: payment
  } do
    pay(series)
    payment |> Repo.reload!() |> Changeset.change(status: :disputed) |> Repo.update!()

    assert :ok = ChargeDisputeClosed.handle(dispute_closed("won"))

    refute_enqueued(worker: RefundLatePayment)
  end

  test "abandoning the checkout from the first session ends the series' checkout" do
    [first | _rest] = meetings()

    expect(StripeAdapterMock, :expire_checkout_session, fn id, opts ->
      assert id == session_id()
      assert opts[:connect_account] == account()
      {:ok, %{}}
    end)

    assert :ok = MeetingPayments.abandon_checkout(first.id)
  end

  describe "the host's outstanding refunds" do
    setup %{series: series} do
      pay(series)
      :ok
    end

    test "do not list a series while any session goes ahead", %{host: host} do
      [first, second, _third] = meetings()
      set_status(first, :cancelled)
      set_status(second, :cancelled)

      assert outstanding(host) == []
      assert %{count: 0} = MeetingPayments.outstanding_refunds_summary_for_host(host.user.id)
    end

    test "list a series once none goes ahead, by its first session still there", %{
      host: host,
      payment: payment
    } do
      [first, second, third] = meetings()
      Repo.delete!(first)
      set_status(second, :cancelled)
      set_status(third, :cancelled)

      assert [listed] = outstanding(host)
      assert listed.id == payment.id
      assert listed.meeting.id == second.id

      assert %{count: 1, totals: [%{currency: "eur", amount_cents: 15_000}]} =
               MeetingPayments.outstanding_refunds_summary_for_host(host.user.id)
    end
  end

  describe "a cancelled session's email" do
    setup %{series: series} do
      pay(series)
      :ok
    end

    test "shows no balance while other sessions go ahead" do
      [first, _second, _third] = meetings()
      cancelled = set_status(first, :cancelled)

      details = AppointmentBuilder.from_meeting(cancelled)

      assert details.booking_payment == nil
      assert RefundNotice.build(details) == nil
    end

    test "shows what is left of the series once none goes ahead", %{payment: payment} do
      payment
      |> Repo.reload!()
      |> Changeset.change(refunded_amount_cents: 5_000, status: :partially_refunded)
      |> Repo.update!()

      [last | _rest] = meetings() |> Enum.map(&set_status(&1, :cancelled)) |> Enum.reverse()

      assert %{amount: amount} = last |> AppointmentBuilder.from_meeting() |> RefundNotice.build()
      assert amount =~ "100.00"
    end
  end

  test "releasing one session of a paid series refunds nothing on its own", %{
    series: series,
    payment: payment
  } do
    pay(series)

    # A request never confirmed before, which a release would otherwise
    # refund in full.
    [first | _rest] = meetings()
    first = first |> Changeset.change(first_announced_at: nil) |> Repo.update!()

    # No refund is expected of Stripe: an unexpected call fails the test.
    assert :ok = ApprovalRefunds.refund_unapproved_request(first)
    assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
  end

  defp dispute_closed(outcome) do
    %{
      "id" => "evt_DISPUTE_#{outcome}",
      "account" => account(),
      "type" => "charge.dispute.closed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "dp_SERIES",
          "object" => "dispute",
          "charge" => "ch_SERIES",
          "amount" => total(),
          "status" => outcome
        }
      }
    }
  end
end
