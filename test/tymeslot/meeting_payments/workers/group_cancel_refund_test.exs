defmodule Tymeslot.MeetingPayments.Workers.GroupCancelRefundTest do
  @moduledoc """
  The job refunding one paid seat of a group session its host cancelled:
  the refund made once, a refusal discarded with the host told, a transient
  Stripe error retried.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.Emails.Templates.SeriesRefundFailed
  alias Tymeslot.Emails.Templates.SeriesRefundFailed.RefundContext
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.GroupCancelRefund
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SendSeriesRefundFailed

  setup :verify_on_exit!

  setup do
    host = insert(:user, email: "host@example.com", name: "Grace Host")
    insert(:profile, user: host, timezone: "Etc/UTC")

    payment =
      insert(:paid_booking_payment,
        seat_payment: true,
        seats: 1,
        amount_cents: 2000,
        host_user_id: host.id,
        host_email: host.email,
        host_name: "Grace Host",
        attendee_name: "Ada Lovelace",
        meeting_type_name: "Group Class",
        stripe_charge_id: "ch_SEAT",
        stripe_account_id: "acct_SEAT"
      )

    Oban.insert!(GroupCancelRefund.new_for(payment, host.id, 2000))
    %{host: host, payment: payment}
  end

  defp run_job(opts \\ []) do
    assert [job] = all_enqueued(worker: GroupCancelRefund)

    job
    |> struct!(Keyword.merge([attempt: 1, attempted_at: DateTime.utc_now()], opts))
    |> perform_job([])
  end

  defp refund_by_host(payment, cents) do
    payment
    |> Changeset.change(status: :partially_refunded, refunded_amount_cents: cents)
    |> Repo.update!()
  end

  defp expect_refund do
    expect(StripeAdapterMock, :create_refund, fn params, opts ->
      assert params.charge == "ch_SEAT"
      assert params.amount == 2000
      assert opts[:idempotency_key] =~ "group_cancel_refund:"
      {:ok, %{id: "re_SEAT"}}
    end)
  end

  test "refunds the amount through issue_host_refund", %{payment: payment} do
    expect_refund()

    assert :ok = run_job()

    reloaded = Repo.reload!(payment)
    assert reloaded.refunded_amount_cents == 2000
    assert reloaded.status == :refunded
  end

  test "treats an earlier attempt's refund as made", %{payment: payment} do
    expect_refund()
    assert :ok = run_job()

    # The same job run again (rescued after it recorded the refund) makes
    # no second Stripe call.
    assert :ok = run_job(attempt: 2)
    assert Repo.reload!(payment).refunded_amount_cents == 2000
  end

  test "refunds only what a refund the host made in between left", %{payment: payment} do
    payment
    |> Changeset.change(status: :partially_refunded, refunded_amount_cents: 500)
    |> Repo.update!()

    expect(StripeAdapterMock, :create_refund, fn %{amount: 1500}, _opts ->
      {:ok, %{id: "re_SEAT"}}
    end)

    assert :ok = run_job()
    assert %{refunded_amount_cents: 2000, status: :refunded} = Repo.reload!(payment)
  end

  test "succeeds with no refund and no email once the payment was refunded in full", %{
    payment: payment
  } do
    payment
    |> Changeset.change(status: :refunded, refunded_amount_cents: 2000)
    |> Repo.update!()

    # No Stripe call is expected: Mox fails the test on one.
    assert :ok = run_job()
    refute_enqueued(worker: SendSeriesRefundFailed)
    assert Repo.reload!(payment).refunded_amount_cents == 2000
  end

  test "discards outside the refund window and emails the host", %{payment: payment} do
    payment
    |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day))
    |> Repo.update!()

    assert {:discard, :outside_refund_window} = run_job()

    assert [%{args: args}] = all_enqueued(worker: SendSeriesRefundFailed)

    assert %{
             "booking_payment_id" => payment_id,
             "amount_cents" => 2000,
             "reason" => "outside_refund_window",
             "context" => "group_meeting"
           } = args

    assert payment_id == payment.id
  end

  test "retries a transient Stripe error", %{payment: payment} do
    expect(StripeAdapterMock, :create_refund, fn _params, _opts -> {:error, :api_error} end)

    assert {:error, :api_error} = run_job()
    refute_enqueued(worker: SendSeriesRefundFailed)
    assert Repo.reload!(payment).refunded_amount_cents == 0
  end

  describe "a retry after a host refund shrank what remains" do
    test "refunds what remains when Stripe refused the first attempt", %{payment: payment} do
      expect(StripeAdapterMock, :create_refund, fn %{amount: 2000}, _opts ->
        {:error, %Stripe.Error{source: :stripe, code: :api_error, message: "try later"}}
      end)

      assert {:error, %Stripe.Error{source: :stripe}} = run_job()
      refund_by_host(payment, 500)

      expect(StripeAdapterMock, :create_refund, fn %{amount: 1500}, _opts ->
        {:ok, %{id: "re_SEAT"}}
      end)

      assert :ok = run_job(attempt: 2)
      assert %{refunded_amount_cents: 2000, status: :refunded} = Repo.reload!(payment)
    end

    test "replays the pinned amount when Stripe may have refunded it", %{payment: payment} do
      # Stripe's answer never comes back: the refund may have been made.
      expect(StripeAdapterMock, :create_refund, fn %{amount: 2000}, _opts ->
        exit({:timeout, {GenServer, :call, []}})
      end)

      assert {:error, {:exit, _timeout}} = run_job()
      refund_by_host(payment, 500)

      # The retry keeps the pinned 2000. The recorded 500 of refunds cannot
      # hold it, so it is no refund Stripe made, and Stripe is not asked
      # (Mox fails any call): the job is discarded.
      assert {:discard, :invalid_amount} = run_job(attempt: 2)
    end
  end

  describe "the host's email when the refund was not made" do
    setup do
      Application.put_env(:swoosh, :shared_test_process, self())
      on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    end

    test "is worded for a cancelled group session", %{host: host, payment: payment} do
      session =
        insert(:group_meeting,
          organizer_user: host,
          title: "Saturday class",
          start_time: ~U[2030-03-02 10:00:00Z],
          end_time: ~U[2030-03-02 10:30:00Z],
          status: :cancelled
        )

      payment |> Changeset.change(meeting_id: session.id) |> Repo.update!()

      %{changes: %{args: args}} =
        SendSeriesRefundFailed.new_for(payment.id, 2000, 0, :api_error, context: :group_meeting)

      assert :ok = perform_job(SendSeriesRefundFailed, args)

      assert_received {:email, email}
      assert email.subject == "Group session refund not made: €20.00"
      assert email.text_body =~ "You cancelled a group session"
      assert email.text_body =~ "Group Class"
      assert email.text_body =~ "Ada Lovelace"
      assert email.text_body =~ "€20.00"
      assert email.text_body =~ "2 March 2030"
      assert email.text_body =~ "from your Stripe dashboard"
    end

    test "keeps the series wording by default" do
      email =
        SeriesRefundFailed.render(%RefundContext{
          host_email: "host@example.com",
          amount_cents: 2000,
          currency: "eur",
          meeting_start: ~U[2030-03-02 10:00:00Z]
        })

      assert email.subject == "Series refund not made: €20.00"
      assert email.text_body =~ "remaining sessions of a series"
      refute email.text_body =~ "2030"
    end
  end
end
