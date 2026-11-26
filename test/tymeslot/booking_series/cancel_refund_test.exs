defmodule Tymeslot.BookingSeries.CancelRefundTest do
  @moduledoc """
  "Cancel all remaining" on a paid series: the host refunds the remaining
  sessions' share once, recorded with the cancellation and made by its
  `ExecuteRefund` job outside it, or a custom amount, or nothing; a payment
  that can no longer be refunded is said so up front; a refund Stripe will
  not make is emailed to the host; and an open paid request is refunded in
  full.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.BookingSeriesTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.BookingSeries
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.SendRefundFailed

  setup :verify_on_exit!

  setup do
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)

    stub(CalendarMock, :get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    :ok
  end

  defp pay(series, count) do
    event = Paid.completed_event("evt_PAID", series.id, count * Paid.price_cents())
    assert :ok = CheckoutSessionCompleted.handle(event)
  end

  # `prior` is what Stripe has refunded on the charge before this refund.
  defp expect_refund(amount, prior \\ 0) do
    StripeStub.expect(:create_refund, 1, fn request ->
      assert request.form["charge"] == "ch_SERIES"
      assert request.form["amount"] == to_string(amount)
      StripeStubResponses.refund(request, "re_SERIES_#{amount}", prior)
    end)
  end

  # Stripe makes the refund, but its answer never comes back: the client
  # sends the lost call 3 times in all, under the same key.
  defp timeout_after_stripe_refunds(amount) do
    StripeStub.expect(:create_refund, 3, fn request ->
      assert request.form["amount"] == to_string(amount)
      {:transport_error, :timeout}
    end)
  end

  # The charge's refunds, as the next attempt or `charge.refunded` lists
  # them: the one made for `refund`, its charge showing Stripe's refunded
  # total.
  defp expect_listed_refund(refund, charge_refunded) do
    StripeStub.expect(
      :list_refunds,
      StripeFixtures.list([
        StripeFixtures.object("refund_with_charge", %{
          "id" => "re_SERIES_LISTED",
          "amount" => refund.amount_cents,
          "metadata" => %{"tymeslot_refund_id" => refund.id},
          "charge" => %{"amount_refunded" => charge_refunded}
        })
      ])
    )
  end

  defp charge_refunded_event(event_id, amount_refunded) do
    %{
      "id" => event_id,
      "account" => Paid.account(),
      "type" => "charge.refunded",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "ch_SERIES",
          "object" => "charge",
          "amount_refunded" => amount_refunded
        }
      }
    }
  end

  defp cancel_as_host(series, host, opts \\ []),
    do:
      BookingSeries.cancel_remaining(
        series,
        [caller: :organizer, acting_user: host.user] ++ opts
      )

  defp refunds(payment),
    do: Repo.all(from(r in RefundSchema, where: r.booking_payment_id == ^payment.id))

  defp refund_failed_jobs, do: all_enqueued(worker: SendRefundFailed)

  # Runs the one refund the series' cancellation recorded, as its job would.
  defp run_refund_job(opts \\ []) do
    assert [refund] =
             Repo.all(
               from(r in RefundSchema, where: r.source in [:series_host, :approval_release])
             )

    perform_job(ExecuteRefund, %{refund_id: refund.id},
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: 10
    )
  end

  # The payment was taken outside the refund window.
  defp paid_long_ago!(series) do
    series.id
    |> BookingPayments.payment_for_series()
    |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day))
    |> Repo.update!()
  end

  describe "a paid series" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      # The completed webhook backfills the charge the refunds are made on.
      Paid.stub_charge_backfill()

      host = Paid.paid_host()
      Paid.expect_checkout()

      assert {:ok, :payment_required, %{series: series}} =
               Paid.book(host, Paid.paid_series_type(host), 4)

      %{host: host, series: series, payment: BookingPayments.payment_for_series(series.id)}
    end

    test "the host's default refund for a paid series is the remaining sessions' share", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      meetings() |> hd() |> into_the_past!()

      assert {:ok, %{cancelled: [_second, _third, _fourth], refund: {:scheduled, 15_000}}} =
               cancel_as_host(series, host)

      assert statuses() == [:confirmed, :cancelled, :cancelled, :cancelled]

      # Recorded with the cancellation; nothing is asked of Stripe until its
      # job runs, outside it.
      host_id = host.user.id

      assert [%{source: :series_host, amount_cents: 15_000, requested_by_user_id: ^host_id}] =
               refunds(payment)

      assert StripeStub.requests(:create_refund) == []
      assert Repo.reload!(payment).refunded_amount_cents == 0

      expect_refund(15_000)
      assert :ok = run_refund_job()

      assert %{refunded_amount_cents: 15_000, status: :partially_refunded} =
               Repo.reload!(payment)

      # A rerun of the settled refund asks Stripe for nothing more.
      assert :ok = run_refund_job(attempt: 2)
      assert Repo.reload!(payment).refunded_amount_cents == 15_000
    end

    test "the default refund is capped at what an earlier refund left", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      [first | _rest] = meetings()

      expect_refund(16_000)

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(first, host.user.id, {:refund, 16_000})

      assert {:ok, %{cancelled: [_second, _third, _fourth], refund: {:scheduled, 4_000}}} =
               cancel_as_host(series, host)

      expect_refund(4_000, 16_000)
      assert :ok = run_refund_job()
      assert %{refunded_amount_cents: 20_000, status: :refunded} = Repo.reload!(payment)
    end

    test "a refund landing between the cancellation and its job does not stand in for it", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      [first | _rest] = meetings()
      into_the_past!(first)

      assert {:ok, %{refund: {:scheduled, 2_000}}} =
               cancel_as_host(series, host, refund: {:amount, 2_000})

      # The host refunds the past session after the cancellation recorded
      # its refund: the total passes it before its job runs.
      expect_refund(5_000)

      assert {:ok, _refunded} =
               MeetingPayments.refund_now(payment, 5_000, :host, host_user_id: host.user.id)

      expect_refund(2_000, 5_000)
      assert :ok = run_refund_job()
      assert Repo.reload!(payment).refunded_amount_cents == 7_000
    end

    test "a refund the webhook recorded before the retry is not asked for or recorded again", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 2_000}}} =
               cancel_as_host(series, host, refund: {:amount, 2_000})

      timeout_after_stripe_refunds(2_000)
      assert {:error, :pending} = run_refund_job()

      # Stripe reports the refund it made, and the webhook finds it among
      # the charge's refunds and records it on its row, at Stripe's total.
      [refund] = refunds(payment)
      expect_listed_refund(refund, 2_000)
      assert :ok = ChargeRefunded.handle(charge_refunded_event("evt_REFUNDED", 2_000))
      assert %{status: :succeeded} = RefundQueries.get(refund.id)
      assert Repo.reload!(payment).refunded_amount_cents == 2_000

      # The retry finds the refund settled and asks Stripe for nothing.
      assert :ok = run_refund_job(attempt: 2)

      assert length(StripeStub.requests(:create_refund)) == 3
      assert length(StripeStub.requests(:list_refunds)) == 1
      assert %{refunded_amount_cents: 2_000, status: :partially_refunded} = Repo.reload!(payment)
      assert %{status: :succeeded} = RefundQueries.get(refund.id)
      assert refund_failed_jobs() == []
    end

    test "a refund Stripe made but the job failed to record is adopted, not made again", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      [first | _rest] = meetings()
      into_the_past!(first)

      assert {:ok, %{refund: {:scheduled, 15_000}}} = cancel_as_host(series, host)

      # Stripe makes the refund, but its answer never comes back: the
      # attempt fails and nothing of it is recorded.
      timeout_after_stripe_refunds(15_000)
      assert {:error, :pending} = run_refund_job()
      assert Repo.reload!(payment).refunded_amount_cents == 0

      # The host refunds the past session before the job runs again; the
      # pending refund holds its share, so only the rest is refundable.
      expect_refund(5_000)

      assert {:ok, _refunded} =
               MeetingPayments.refund_now(payment, 5_000, :host, host_user_id: host.user.id)

      [refund | _host_refund] = Enum.filter(refunds(payment), &(&1.source == :series_host))
      expect_listed_refund(refund, 20_000)
      assert :ok = run_refund_job(attempt: 2)

      assert %{refunded_amount_cents: 20_000, status: :refunded} = Repo.reload!(payment)
    end

    test "a custom amount", %{host: host, series: series, payment: payment} do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 2_000}}} =
               cancel_as_host(series, host, refund: {:amount, 2_000})

      expect_refund(2_000)
      assert :ok = run_refund_job()
      assert Repo.reload!(payment).refunded_amount_cents == 2_000
    end

    test "no refund", %{host: host, series: series, payment: payment} do
      pay(series, 4)

      assert {:ok, %{cancelled: [_first, _second, _third, _fourth], refund: :none}} =
               cancel_as_host(series, host, refund: :none)

      assert refunds(payment) == []
      assert Repo.reload!(payment).refunded_amount_cents == 0
    end

    test "an amount above what remains is refused before anything is cancelled", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:error, :exceeds_remaining} =
               cancel_as_host(series, host, refund: {:amount, 4 * Paid.price_cents() + 1})

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
      assert refunds(payment) == []
    end

    # The amount fitted when the host chose it, but a refund recorded since
    # holds part of it: the cancellation's transaction is rolled back whole.
    test "an amount a pending refund no longer leaves cancels nothing", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      insert(:booking_payment_refund,
        booking_payment: Repo.reload!(payment),
        amount_cents: 15_000,
        source: :host
      )

      payment_for_choice = %{Repo.reload!(payment) | pending_refund_cents: 0}

      assert {:ok, {:amount, 10_000} = choice} =
               BookingSeries.resolve_refund_choice(payment_for_choice, %{
                 "cancel_refund_choice" => "partial",
                 "cancel_refund_amount" => "100"
               })

      assert {:error, :exceeds_remaining} = cancel_as_host(series, host, refund: choice)

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
      assert [%{amount_cents: 15_000}] = refunds(payment)
    end

    test "past the refund window, the default cancels without a refund and says why", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      paid_long_ago!(series)

      assert {:ok,
              %{
                cancelled: [_first, _second, _third, _fourth],
                refund: {:not_refunded, :outside_refund_window}
              }} = cancel_as_host(series, host)

      assert refunds(payment) == []
    end

    test "past the refund window, an explicit amount is refused with nothing cancelled", %{
      host: host,
      series: series
    } do
      pay(series, 4)
      paid_long_ago!(series)

      assert {:error, :outside_refund_window} =
               cancel_as_host(series, host, refund: {:amount, 1_000})

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
    end

    test "an attendee cancellation of a paid series refunds nothing", %{
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{cancelled: [_first, _second, _third, _fourth], refund: :none}} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert refunds(payment) == []
      assert %{refunded_amount_cents: 0, status: :paid} = Repo.reload!(payment)
    end

    test "sessions awaiting payment are left to the checkout", %{host: host, series: series} do
      assert {:error, :nothing_to_cancel} =
               BookingSeries.cancel_remaining(series, caller: :attendee)

      assert {:error, :nothing_to_cancel} = cancel_as_host(series, host)

      # An explicit amount on a payment still to be made says so.
      assert {:error, :not_paid} = cancel_as_host(series, host, refund: {:amount, 1_000})

      assert statuses() == [
               :awaiting_payment,
               :awaiting_payment,
               :awaiting_payment,
               :awaiting_payment
             ]

      assert email_jobs("send_series_cancellation") == []
      assert is_nil(reload_series(series).cancelled_at)
    end

    test "a series cancellation refunds through the outbox and emails the host on final failure",
         %{host: host, series: series, payment: payment} do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 20_000}}} = cancel_as_host(series, host)
      assert statuses() == [:cancelled, :cancelled, :cancelled, :cancelled]
      assert [_one] = email_jobs("send_series_cancellation")

      # A failed attempt is retried quietly.
      StripeStub.expect(:create_refund, 3, {:transport_error, :timeout})
      assert {:error, :pending} = run_refund_job(attempt: 1)
      assert refund_failed_jobs() == []

      # The last attempt only looks for a refund an earlier one made; with
      # none, the refund fails for good and the host is emailed.
      StripeStub.expect(:list_refunds, StripeFixtures.list([]))
      assert {:cancel, :refund_failed} = run_refund_job(attempt: 10)

      [refund] = refunds(payment)
      assert %{status: :failed, failure_code: "retries_exhausted"} = refund
      refund_id = refund.id
      assert [%{args: %{"refund_id" => ^refund_id}}] = refund_failed_jobs()
      assert Repo.reload!(payment).refunded_amount_cents == 0
    end

    test "a refund Stripe declines emails the host at once", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      assert {:ok, %{refund: {:scheduled, 20_000}}} = cancel_as_host(series, host)

      StripeStub.expect(:create_refund, {:error_fixture, "invalid_request_error"})
      assert {:cancel, :refund_failed} = run_refund_job()

      assert [%{args: %{"refund_id" => _id}}] = refund_failed_jobs()
      assert Repo.reload!(payment).refunded_amount_cents == 0
    end
  end

  describe "an open paid request" do
    test "the host cancelling an open paid request refunds it in full, whatever the option" do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      Paid.stub_charge_backfill()

      host = Paid.paid_host()

      type =
        host
        |> Paid.paid_series_type()
        |> Changeset.change(requires_approval: true)
        |> Repo.update!()

      Paid.expect_checkout()
      assert {:ok, :payment_required, %{series: series}} = Paid.book(host, type, 3)
      pay(series, 3)
      assert statuses() == [:awaiting_approval, :awaiting_approval, :awaiting_approval]

      assert {:ok, %{cancelled: [_first, _second, _third], refund: {:refunded, 15_000}}} =
               cancel_as_host(series, host, refund: :none)

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert StripeStub.requests(:create_refund) == []

      payment = BookingPayments.payment_for_series(series.id)
      assert [%{source: :approval_release, amount_cents: 15_000}] = refunds(payment)

      expect_refund(15_000)
      assert :ok = run_refund_job()
      assert %{refunded_amount_cents: 15_000, status: :refunded} = Repo.reload!(payment)

      assert [%{args: %{"cancelled_by" => "organizer"}}] =
               email_jobs("send_series_cancellation")
    end
  end
end
