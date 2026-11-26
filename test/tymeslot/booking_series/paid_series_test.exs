defmodule Tymeslot.BookingSeries.PaidSeriesTest do
  @moduledoc """
  A paid series end to end: booked with every session held for one Stripe
  Checkout at the whole price, confirmed whole when the payment completes,
  released whole when it lapses, and refunded a session at a time when the
  host cancels one.
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
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.CalendarMock

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SeriesAnnouncementWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 50
    )

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    host = paid_host()
    %{host: host, type: paid_series_type(host)}
  end

  defp meetings,
    do:
      Repo.all(
        from(m in MeetingSchema, where: not is_nil(m.series_id), order_by: m.series_position)
      )

  defp statuses, do: Enum.map(meetings(), & &1.status)
  defp payments, do: Repo.all(BookingPaymentSchema)

  defp calendar_creates,
    do: all_enqueued(worker: CalendarEventWorker, args: %{"action" => "create"})

  # Books three sessions and returns the series and its pending payment.
  defp book_three(host, type) do
    expect_checkout()

    assert {:ok, :payment_required, %{series: series, checkout_url: url}} =
             book(host, type, 3)

    assert url =~ session_id()
    {series, BookingPayments.payment_for_series(series.id)}
  end

  defp total, do: 3 * price_cents()

  defp pay(series),
    do:
      assert(
        :ok = CheckoutSessionCompleted.handle(completed_event("evt_PAID", series.id, total()))
      )

  defp lapse(series),
    do: assert(:ok = CheckoutSessionExpired.handle(expired_event("evt_EXPIRED", series.id)))

  defp available?(type) do
    {:ok, occurrences} = BookingSeries.preview(type, at(7), count: 3)
    Enum.all?(occurrences, &Occurrence.available?/1)
  end

  test "a paid series holds every occurrence until paid", %{host: host, type: type} do
    expect_checkout()

    assert {:ok, :payment_required, %{series: series, meeting: first, meetings: held}} =
             book(host, type, 3)

    assert_received {:checkout, form, headers}

    assert statuses() == [:awaiting_payment, :awaiting_payment, :awaiting_payment]
    assert first.id == hd(held).id and first.series_position == 1
    assert %SeriesSchema{unit_price_cents: 5_000} = Repo.get!(SeriesSchema, series.id)

    assert [payment] = payments()
    assert payment.series_id == series.id
    assert payment.meeting_id == nil
    assert payment.status == :pending
    assert payment.amount_cents == total()
    assert payment.stripe_checkout_session_id == session_id()

    assert [%{"price_data" => %{"unit_amount" => "5000"}, "quantity" => "3"} = item] =
             form["line_items"]

    assert item["price_data"]["product_data"]["name"] == "Mentoring, 3 sessions"
    assert form["client_reference_id"] == "series:#{series.id}"
    assert form["payment_intent_data"]["metadata"]["series_id"] == to_string(series.id)
    assert form["success_url"] =~ "/payment-processing/#{first.id}?session_id="
    assert form["cancel_url"] =~ "/payment-cancelled/#{first.id}?"
    assert headers["idempotency-key"] == "tymeslot:series_checkout:#{series.id}"

    # Nothing is done for a held session until it is paid for.
    assert calendar_creates() == []
    refute_enqueued(worker: SeriesAnnouncementWorker)
    refute_enqueued(worker: EmailWorker)
    refute available?(type)
  end

  test "the application fee is computed on the total", %{host: host, type: type} do
    {_series, payment} = book_three(host, type)
    assert_received {:checkout, form, _headers}

    # 0.5% of 150.00, where a session alone would take 0.25.
    assert payment.application_fee_cents == 75
    assert form["payment_intent_data"]["application_fee_amount"] == "75"
  end

  test "paying confirms every occurrence and sends one confirmation", %{host: host, type: type} do
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.EmailServiceMock)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    {series, payment} = book_three(host, type)
    [first | _rest] = meetings()
    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, Checkout.payment_topic(first.id))

    pay(series)

    assert statuses() == [:confirmed, :confirmed, :confirmed]
    assert %{status: :paid, paid_at: %DateTime{}} = Repo.reload!(payment)
    assert_received :paid

    assert calendar_creates() |> Enum.map(& &1.args["meeting_id"]) |> Enum.sort() ==
             meetings() |> Enum.map(& &1.id) |> Enum.sort()

    assert jobs = all_enqueued(worker: SeriesAnnouncementWorker)
    assert [%{args: %{"series_id" => series_id}}] = jobs
    assert series_id == series.id

    assert all_enqueued(worker: EmailWorker, args: %{"action" => "send_confirmation_emails"}) ==
             []

    assert :ok = perform_job(SeriesAnnouncementWorker, %{"series_id" => series.id})
    assert %{success: 2} = Oban.drain_queue(queue: :emails, with_recursion: true)

    assert_received {:email, first_email}
    assert_received {:email, second_email}
    refute_received {:email, _third}

    for email <- [first_email, second_email] do
      assert email.text_body =~ "Total paid: €150.00"
    end
  end

  test "an expired checkout releases every occurrence", %{host: host, type: type} do
    {series, payment} = book_three(host, type)
    [first | _rest] = meetings()
    :ok = Phoenix.PubSub.subscribe(Tymeslot.PubSub, Checkout.payment_topic(first.id))

    lapse(series)

    assert statuses() == [:expired, :expired, :expired]
    assert Repo.reload!(payment).status == :failed
    assert_received :expired
    refute_received :expired
    assert available?(type)
  end

  test "a late payment with every slot still free reinstates the series", %{
    host: host,
    type: type
  } do
    {series, payment} = book_three(host, type)
    lapse(series)

    pay(series)

    assert statuses() == [:confirmed, :confirmed, :confirmed]
    assert Repo.reload!(payment).status == :paid
    assert length(calendar_creates()) == 3
    assert [_announcement] = all_enqueued(worker: SeriesAnnouncementWorker)
    assert late_refunds(payment) == []
  end

  test "a late payment with one slot taken refunds in full and reinstates nothing", %{
    host: host,
    type: type
  } do
    {series, payment} = book_three(host, type)
    lapse(series)

    # Overlapping the second session, not starting with it, so only the
    # conflict count can find it.
    taken = DateTime.add(at(14), 15, :minute)

    insert(:meeting,
      organizer_user_id: host.user.id,
      start_time: taken,
      end_time: DateTime.add(taken, 30, :minute),
      status: :confirmed
    )

    pay(series)

    assert statuses() == [:expired, :expired, :expired]
    assert Repo.reload!(payment).status == :paid
    assert [%{source: :late_payment}] = late_refunds(payment)
    assert calendar_creates() == []
    refute_enqueued(worker: SeriesAnnouncementWorker)
  end

  test "a checkout failure expires the series at once", %{host: host, type: type} do
    expect_checkout({:error_fixture, "api_error"})

    assert {:error, :checkout_failed} = book(host, type, 3)

    assert statuses() == [:expired, :expired, :expired]
    assert available?(type)
  end

  describe "cancelling one paid session" do
    setup %{host: host, type: type} do
      # The completed webhook backfills the charge the refunds are made on.
      stub_charge_backfill()

      {series, payment} = book_three(host, type)
      pay(series)
      %{series: series, payment: Repo.reload!(payment)}
    end

    test "the host's default refund for one occurrence is one session's price", %{
      host: host,
      series: series,
      payment: payment
    } do
      [_first, second, _third] = meetings()
      held = BookingPayments.payment_for_meeting(second.id, host.user.id)
      assert held.id == payment.id

      assert {:ok, {:refund, 5_000}} = Meetings.resolve_cancellation_refund(held, %{})

      StripeStub.expect(:create_refund, 1, fn request ->
        assert request.form["charge"] == "ch_SERIES"
        assert request.form["amount"] == "5000"

        assert %{
                 "series_id" => series_id,
                 "booking_payment_id" => payment_id,
                 "tymeslot_refund_id" => _refund_id
               } = request.form["metadata"]

        assert series_id == to_string(series.id)
        assert payment_id == to_string(payment.id)
        refute Map.has_key?(request.form["metadata"], "meeting_id")

        StripeStubResponses.refund(request, "re_SESSION")
      end)

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(second, host.user.id, {:refund, 5_000})

      assert %{refunded_amount_cents: 5_000, status: :partially_refunded} =
               Repo.reload!(payment)

      assert statuses() == [:confirmed, :cancelled, :confirmed]
    end

    test "refunds never exceed what remains", %{host: host, payment: payment} do
      payment
      |> Changeset.change(refunded_amount_cents: 12_000, status: :partially_refunded)
      |> Repo.update!()

      [first | _rest] = meetings()
      held = BookingPayments.payment_for_meeting(first.id, host.user.id)

      assert {:ok, {:refund, 3_000}} = Meetings.resolve_cancellation_refund(held, %{})
    end

    test "an attendee cancellation of one paid session refunds nothing", %{payment: payment} do
      [first | _rest] = meetings()

      # No refund is expected of Stripe: an unexpected call fails the test.
      assert {:ok, _cancelled} = Meetings.cancel_meeting(first)

      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
      assert statuses() == [:cancelled, :confirmed, :confirmed]

      # Announced for that one session, as any cancellation is.
      assert [%{args: %{"meeting_id" => cancelled_id}}] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_cancellation_emails"})

      assert cancelled_id == first.id
    end
  end

  defp late_refunds(payment),
    do: Repo.all(from(r in RefundSchema, where: r.booking_payment_id == ^payment.id))
end
