defmodule Tymeslot.BookingSeries.CancelRefundTest do
  @moduledoc """
  "Cancel all remaining" on a paid series: the host refunds the remaining
  sessions' share once, through a job outside the cancellation
  (`Tymeslot.MeetingPayments.Workers.SeriesHostRefund`), or a custom amount,
  or nothing; a payment that can no longer be refunded is said so up front;
  and an open paid request is refunded in full.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.BookingSeriesTestHelpers
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.BookingSeries
  alias Tymeslot.CalendarMock
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.ChargeRefunded
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.SeriesHostRefund
  alias Tymeslot.Meetings
  alias Tymeslot.PaidSeriesTestHelpers, as: Paid
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendSeriesRefundFailed

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

  defp expect_refund(amount) do
    expect(StripeAdapterMock, :create_refund, 1, fn params, _opts ->
      assert params.charge == "ch_SERIES"
      assert params.amount == amount
      {:ok, %{id: "re_SERIES"}}
    end)
  end

  # Stripe makes the refund, but its answer never comes back.
  defp timeout_after_stripe_refunds(amount) do
    expect(StripeAdapterMock, :create_refund, 1, fn %{amount: ^amount}, opts ->
      send(self(), {:refund_key, opts[:idempotency_key]})
      exit({:timeout, {GenServer, :call, []}})
    end)
  end

  # Stripe answers a replayed key with the refund it made then, its charge
  # showing the refunded total of that moment.
  defp expect_replayed_refund(amount, charge_refunded) do
    assert_received {:refund_key, first_key}

    expect(StripeAdapterMock, :create_refund, 1, fn %{amount: ^amount}, opts ->
      assert opts[:idempotency_key] == first_key
      {:ok, %{id: "re_SERIES", amount: amount, charge: %{amount_refunded: charge_refunded}}}
    end)
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

  defp refund_jobs, do: all_enqueued(worker: SeriesHostRefund)
  defp refund_failed_jobs, do: all_enqueued(worker: SendSeriesRefundFailed)

  # Runs the one refund job the cancellation inserted, as itself: its id is
  # what a later run of it recognises its refund by.
  defp run_refund_job(opts \\ []) do
    assert [job] = refund_jobs()

    job
    |> struct!(Keyword.merge([attempt: 1, attempted_at: DateTime.utc_now()], opts))
    |> perform_job([])
  end

  # The payment was taken outside the refund window.
  defp paid_long_ago!(series) do
    series.id
    |> MeetingPayments.payment_for_series()
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
      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_SERIES", _opts ->
        {:ok, %{"latest_charge" => "ch_SERIES"}}
      end)

      host = Paid.paid_host()
      Paid.expect_checkout()

      assert {:ok, :payment_required, %{series: series}} =
               Paid.book(host, Paid.paid_series_type(host), 4)

      %{host: host, series: series, payment: MeetingPayments.payment_for_series(series.id)}
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
      # Nothing is refunded until the job runs, outside the cancellation.
      assert Repo.reload!(payment).refunded_amount_cents == 0

      expect_refund(15_000)
      assert :ok = run_refund_job()

      assert %{refunded_amount_cents: 15_000, status: :partially_refunded} =
               Repo.reload!(payment)

      # A retry after the refund was recorded asks Stripe for nothing more.
      assert :ok = run_refund_job()
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

      expect_refund(4_000)
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

      # The host refunds the past session after the cancellation scheduled
      # its job: the total passes what the job will refund before it runs.
      expect_refund(5_000)
      assert {:ok, _refunded} = Refunds.issue_host_refund(payment.id, host.user.id, 5_000)

      expect_refund(2_000)
      assert :ok = run_refund_job()
      assert Repo.reload!(payment).refunded_amount_cents == 7_000

      # Its own refund made, a later run of the same job refunds nothing.
      assert :ok = run_refund_job(attempt: 2)
      assert Repo.reload!(payment).refunded_amount_cents == 7_000
    end

    test "a refund the webhook recorded before the retry is not recorded again", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 2_000}}} =
               cancel_as_host(series, host, refund: {:amount, 2_000})

      timeout_after_stripe_refunds(2_000)
      assert {:error, {:exit, _timeout}} = run_refund_job()

      # Stripe reports the refund it made, so the payment records it.
      assert :ok = ChargeRefunded.handle(charge_refunded_event("evt_REFUNDED", 2_000))
      assert Repo.reload!(payment).refunded_amount_cents == 2_000

      # The 2,000 still fits what remains, so the retry asks Stripe again,
      # which answers with the same refund under the same key.
      expect_replayed_refund(2_000, 2_000)
      assert :ok = run_refund_job(attempt: 2)

      assert %{refunded_amount_cents: 2_000, status: :partially_refunded} = Repo.reload!(payment)
      assert refund_failed_jobs() == []
    end

    test "a refund the webhook recorded is no failure once the rest no longer covers it", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 20_000}}} = cancel_as_host(series, host)

      timeout_after_stripe_refunds(20_000)
      assert {:error, {:exit, _timeout}} = run_refund_job()

      assert :ok = ChargeRefunded.handle(charge_refunded_event("evt_REFUNDED", 20_000))
      assert %{refunded_amount_cents: 20_000, status: :refunded} = Repo.reload!(payment)

      # Nothing remains to refund, yet the refund is this job's own: Stripe
      # answers the retry with it, and the host is told nothing failed.
      expect_replayed_refund(20_000, 20_000)
      assert :ok = run_refund_job(attempt: 2)

      assert %{refunded_amount_cents: 20_000, status: :refunded} = Repo.reload!(payment)
      assert refund_failed_jobs() == []
    end

    test "a refund the webhook recorded is no failure once the rest covers only part of it", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      [first | _rest] = meetings()
      into_the_past!(first)

      assert {:ok, %{refund: {:scheduled, 15_000}}} = cancel_as_host(series, host)

      timeout_after_stripe_refunds(15_000)
      assert {:error, {:exit, _timeout}} = run_refund_job()

      assert :ok = ChargeRefunded.handle(charge_refunded_event("evt_REFUNDED", 15_000))
      assert Repo.reload!(payment).refunded_amount_cents == 15_000

      # 5,000 remains, less than the 15,000 the job refunds.
      expect_replayed_refund(15_000, 15_000)
      assert :ok = run_refund_job(attempt: 2)

      assert %{refunded_amount_cents: 15_000, status: :partially_refunded} =
               Repo.reload!(payment)

      assert refund_failed_jobs() == []
    end

    test "an amount the rest no longer covers, and Stripe never refunded, is still a failure", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 20_000}}} = cancel_as_host(series, host)

      # Refunded elsewhere (the host's Stripe dashboard) before the job ran.
      assert :ok = ChargeRefunded.handle(charge_refunded_event("evt_REFUNDED", 15_000))

      expect(StripeAdapterMock, :create_refund, 1, fn %{amount: 20_000}, _opts ->
        {:error,
         %Stripe.Error{
           source: :stripe,
           code: :invalid_request_error,
           message: "Refund amount is greater than unrefunded amount on charge"
         }}
      end)

      assert {:discard, :invalid_amount} = run_refund_job()
      assert Repo.reload!(payment).refunded_amount_cents == 15_000
      assert [%{args: %{"amount_cents" => 20_000}}] = refund_failed_jobs()
    end

    test "a refund Stripe made but the job failed to record is replayed, not made again", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)
      [first | _rest] = meetings()
      into_the_past!(first)

      assert {:ok, %{refund: {:scheduled, 15_000}}} = cancel_as_host(series, host)
      assert [%{id: job_id}] = refund_jobs()

      # Stripe makes the refund, but its answer never comes back: the
      # attempt fails and nothing of it is recorded.
      expect(StripeAdapterMock, :create_refund, 1, fn %{amount: 15_000}, opts ->
        send(self(), {:refund_key, opts[:idempotency_key]})
        exit({:timeout, {GenServer, :call, []}})
      end)

      assert {:error, {:exit, _timeout}} = run_refund_job()
      assert_received {:refund_key, first_key}
      assert first_key == "series_refund:#{job_id}"
      assert Repo.reload!(payment).refunded_amount_cents == 0

      # The host refunds the past session before the job runs again.
      expect_refund(5_000)
      assert {:ok, _refunded} = Refunds.issue_host_refund(payment.id, host.user.id, 5_000)

      # The retry asks under the same key, so Stripe answers with the refund
      # it already made, which is now recorded once.
      expect(StripeAdapterMock, :create_refund, 1, fn %{amount: 15_000}, opts ->
        assert opts[:idempotency_key] == first_key
        {:ok, %{id: "re_SERIES"}}
      end)

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

      assert refund_jobs() == []
      assert Repo.reload!(payment).refunded_amount_cents == 0
    end

    test "an amount above what remains is refused before anything is cancelled", %{
      host: host,
      series: series
    } do
      pay(series, 4)

      assert {:error, :exceeds_remaining} =
               cancel_as_host(series, host, refund: {:amount, 4 * Paid.price_cents() + 1})

      assert statuses() == [:confirmed, :confirmed, :confirmed, :confirmed]
      assert email_jobs("send_series_cancellation") == []
      assert refund_jobs() == []
    end

    test "past the refund window, the default cancels without a refund and says why", %{
      host: host,
      series: series
    } do
      pay(series, 4)
      paid_long_ago!(series)

      assert {:ok,
              %{
                cancelled: [_first, _second, _third, _fourth],
                refund: {:not_refunded, :outside_refund_window}
              }} = cancel_as_host(series, host)

      assert refund_jobs() == []
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

      assert refund_jobs() == []
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

    test "a refund failure leaves the sessions cancelled and reports it", %{
      host: host,
      series: series,
      payment: payment
    } do
      pay(series, 4)

      assert {:ok, %{refund: {:scheduled, 20_000}}} = cancel_as_host(series, host)
      assert statuses() == [:cancelled, :cancelled, :cancelled, :cancelled]
      assert [_one] = email_jobs("send_series_cancellation")

      expect(StripeAdapterMock, :create_refund, 2, fn _params, _opts -> {:error, :api_error} end)

      # A failed attempt is retried; a refusal no retry turns round is
      # discarded. Either way the money stays on the payment.
      # The host is emailed once the job gives up: on its last attempt, or
      # on a refusal.
      assert {:error, :api_error} = run_refund_job(attempt: 1)
      refute_enqueued(worker: SendSeriesRefundFailed)
      assert {:error, :api_error} = run_refund_job(attempt: 10)
      assert [%{args: %{"amount_cents" => 20_000}}] = refund_failed_jobs()
      paid_long_ago!(series)
      assert {:discard, :outside_refund_window} = run_refund_job(attempt: 2)
      assert [_still_one] = refund_failed_jobs()

      assert Repo.reload!(payment).refunded_amount_cents == 0
    end

    test "a last attempt that exits still tells the host", %{host: host, series: series} do
      pay(series, 4)
      assert {:ok, %{refund: {:scheduled, 20_000}}} = cancel_as_host(series, host)

      # A call that timed out exits rather than raising.
      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        exit({:timeout, {GenServer, :call, []}})
      end)

      assert {:error, {:exit, {:timeout, _call}}} = run_refund_job(attempt: 10)
      assert [%{args: %{"amount_cents" => 20_000}}] = refund_failed_jobs()
    end
  end

  describe "an open paid request" do
    test "the host cancelling an open paid request refunds it in full, whatever the option" do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_SERIES", _opts ->
        {:ok, %{"latest_charge" => "ch_SERIES"}}
      end)

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

      expect_refund(15_000)

      assert {:ok, %{cancelled: [_first, _second, _third], refund: {:refunded, 15_000}}} =
               cancel_as_host(series, host, refund: :none)

      assert statuses() == [:cancelled, :cancelled, :cancelled]
      assert refund_jobs() == []

      assert [%{args: %{"cancelled_by" => "organizer"}}] =
               email_jobs("send_series_cancellation")
    end
  end
end
