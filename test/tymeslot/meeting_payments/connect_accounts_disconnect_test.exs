defmodule Tymeslot.MeetingPayments.ConnectAccountsDisconnectTest do
  # The revocation tests start onboarding, which reads the global
  # meeting-payments flag and the Connect client ID, both changed here.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.StripeConnectTestHelpers

  alias Oban.Job
  alias Oban.Worker
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountRetirement
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.DeauthorizeConnectAccount
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  setup :verify_on_exit!

  describe "disconnect/1" do
    test "soft-deletes the live account" do
      user = insert(:user)
      {:ok, _placeholder} = ConnectAccountQueries.insert_placeholder(user.id)

      assert {:ok, %{cancelled_count: 0}} = ConnectAccountRetirement.disconnect(user)

      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "is a noop when no account exists" do
      user = insert(:user)
      assert {:ok, %{cancelled_count: 0}} = ConnectAccountRetirement.disconnect(user)
    end

    test "does not overwrite a payment that was concurrently transitioned to paid" do
      # Regression for the TOCTOU race: list_pending_for_host runs outside the
      # transaction and snapshots the payment as "pending". Before the transaction
      # executes, a concurrent checkout.session.completed webhook flips the same
      # row to "paid". The conditional UPDATE (status = 'pending') must skip that
      # row so the paid status is preserved and cancelled_count stays accurate.
      user = insert(:user)
      {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id)

      payment =
        insert(:booking_payment,
          host_user_id: user.id,
          stripe_checkout_session_id: "cs_race_test",
          status: :pending
        )

      # Simulate the concurrent webhook arriving: flip the row to "paid" directly.
      {:ok, _updated} = BookingPaymentQueries.update(payment, %{status: :paid})

      # disconnect/1 pre-fetches the payment as "pending" (it was pending when
      # list_pending_for_host ran), but inside the transaction the conditional
      # UPDATE finds status = 'paid' and must not overwrite it.
      stub(StripeAdapterMock, :expire_checkout_session, fn _session_id, _opts ->
        {:error, %{message: "already paid"}}
      end)

      assert {:ok, %{cancelled_count: 0}} = ConnectAccountRetirement.disconnect(user)

      # The payment row must still be "paid" — not "failed".
      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == :paid
    end

    # A row that no longer passes the full meeting validation (here a solo
    # meeting with no attendee name, as older rows can carry) must still
    # have its slot released.
    test "expires a pending booking's meeting whose other fields no longer pass validation" do
      user = insert(:user)
      {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id)
      meeting = insert(:meeting, status: :awaiting_payment, organizer_user_id: user.id)

      Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id), set: [attendee_name: nil])

      insert(:booking_payment,
        host_user_id: user.id,
        meeting: meeting,
        stripe_checkout_session_id: "cs_LEGACY",
        status: :pending
      )

      stub(StripeAdapterMock, :expire_checkout_session, fn _session_id, _opts -> {:ok, %{}} end)

      assert {:ok, %{cancelled_count: 1}} = ConnectAccountRetirement.disconnect(user)
      assert {:ok, %{status: :expired}} = MeetingQueries.get_meeting(meeting.id)
    end

    # Disconnecting neither settles nor cancels a refund the host already owes;
    # it only takes away their ability to issue it from Tymeslot. The count is
    # reported so the caller can say so, rather than let the obligation drop
    # off the screen along with the account.
    test "reports the refunds the host is still holding" do
      user = insert(:user)
      {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id)

      meeting = insert(:meeting, status: :cancelled, cancelled_at: DateTime.utc_now(:second))
      payment = insert(:paid_booking_payment, host_user_id: user.id, meeting: meeting)

      assert {:ok, %{outstanding_refunds_count: 1}} = ConnectAccountRetirement.disconnect(user)

      # Untouched: still owed, still unrefunded, just no longer refundable here.
      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == :paid
      assert reloaded.refunded_amount_cents == 0
    end

    test "reports no outstanding refunds when the host owes nothing" do
      user = insert(:user)
      {:ok, _account} = ConnectAccountQueries.insert_placeholder(user.id)

      insert(:paid_booking_payment,
        host_user_id: user.id,
        meeting: insert(:meeting, status: :confirmed)
      )

      assert {:ok, %{outstanding_refunds_count: 0}} = ConnectAccountRetirement.disconnect(user)
    end
  end

  describe "disconnect/1 revoking access" do
    setup :enable_meeting_payments

    test "disconnecting an OAuth account schedules revocation after checkouts can have ended" do
      user = insert(:user)

      insert(:connect_account,
        user: user,
        stripe_account_id: "acct_OA",
        oauth_connected_at: DateTime.utc_now(:second)
      )

      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      assert_enqueued(
        worker: DeauthorizeConnectAccount,
        args: %{stripe_account_id: "acct_OA"},
        scheduled_at: {DateTime.add(DateTime.utc_now(:second), 35 * 60), delta: 60}
      )
    end

    test "disconnecting a legacy account schedules its revocation too" do
      user = insert(:user)
      insert(:connect_account, user: user, stripe_account_id: "acct_LEG")

      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      refute ConnectAccountQueries.live_for_user(user.id)

      assert_enqueued(
        worker: DeauthorizeConnectAccount,
        args: %{stripe_account_id: "acct_LEG"},
        scheduled_at: {DateTime.add(DateTime.utc_now(:second), 35 * 60), delta: 60}
      )
    end

    test "reconnecting the same account before revocation keeps it" do
      user = insert(:user)
      connect_account(user, "acct_X")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      connect_account(user, "acct_X")

      # No `deauthorize_account` expectation: Mox fails the job on any call.
      assert %{success: 1, failure: 0} =
               Oban.drain_queue(queue: :payments, with_scheduled: true)

      assert ConnectAccountQueries.live_for_user(user.id).stripe_account_id == "acct_X"
    end

    test "a later disconnect pushes back a revocation still pending" do
      user = insert(:user)
      connect_account(user, "acct_X")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      # The first job is now older than the worker's own 60-second window.
      long_ago = DateTime.add(DateTime.utc_now(:second), -600)

      Repo.update_all(
        from(j in Job, where: j.worker == ^Worker.to_string(DeauthorizeConnectAccount)),
        set: [inserted_at: long_ago, scheduled_at: DateTime.add(long_ago, 120)]
      )

      connect_account(user, "acct_X")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      assert [job] = all_enqueued(worker: DeauthorizeConnectAccount)
      assert job.args == %{"stripe_account_id" => "acct_X"}

      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now(:second)),
                      35 * 60,
                      60
    end

    test "an OAuth account is revoked once the delay has passed" do
      user = insert(:user)
      connect_account(user, "acct_X")
      assert {:ok, _result} = ConnectAccountRetirement.disconnect(user)

      expect(StripeAdapterMock, :deauthorize_account, 1, fn "acct_X" -> :ok end)

      assert %{success: 1, failure: 0} =
               Oban.drain_queue(queue: :payments, with_scheduled: true)
    end
  end
end
