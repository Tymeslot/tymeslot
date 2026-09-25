defmodule Tymeslot.Meetings.CancellationTest do
  @moduledoc """
  Cancelling a paid meeting with a refund, from the point of view of who asks.

  A refund moves the host's money, so only the host who took the payment may
  ask for one. Anyone else who is allowed to cancel the meeting (its attendee,
  signed in under the booking address) cancels it without a refund. A refused
  refund must be refused before the meeting is touched: cancelling first and
  then failing would report a refund problem for a refund nobody was entitled
  to request.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meetings
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()

    %{user: host} = create_user_with_profile()
    %{user: attendee} = create_user_with_profile()

    meeting =
      insert_meeting_for_user(host, %{attendee_email: attendee.email, start_offset: 3 * 86_400})

    payment =
      insert(:paid_booking_payment,
        meeting_id: meeting.id,
        host_user_id: host.id,
        host_email: host.email,
        stripe_account_id: "acct_CANCELLATION"
      )

    {:ok, host: host, attendee: attendee, meeting: meeting, payment: payment}
  end

  describe "cancel_meeting_with_refund/3 by the host who took the payment" do
    test "cancels the meeting and refunds the requested amount", %{
      host: host,
      meeting: meeting,
      payment: payment
    } do
      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == payment.stripe_charge_id
        assert params.amount == 2000
        {:ok, %{id: "re_host_cancel"}}
      end)

      assert {:ok, cancelled} =
               Meetings.cancel_meeting_with_refund(meeting, host.id, {:refund, 2000})

      assert cancelled.status == "cancelled"

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.refunded_amount_cents == 2000
      assert reloaded.status == "partially_refunded"

      assert_enqueued(worker: SendBookingPaymentRefunded, args: %{booking_payment_id: payment.id})
    end
  end

  # The host's cancellation email reports what they still hold for the
  # booking, read from the payment when the email is built. Announced before
  # the refund, it tells the host they owe money they have just paid back.
  describe "cancel_meeting_with_refund/3 and the cancellation email" do
    @cancellation_email [worker: EmailWorker, args: %{action: "send_cancellation_emails"}]

    test "is only queued once the refund has gone through", %{host: host, meeting: meeting} do
      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        refute_enqueued(@cancellation_email)
        {:ok, %{id: "re_before_email"}}
      end)

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(meeting, host.id, {:refund, 5000})

      assert_enqueued(@cancellation_email ++ [args: %{meeting_id: meeting.id}])
    end

    test "is still queued when the refund fails", %{host: host, meeting: meeting} do
      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:error, %{message: "card_declined"}}
      end)

      assert {:error, {:refund_failed, _reason}} =
               Meetings.cancel_meeting_with_refund(meeting, host.id, {:refund, 5000})

      assert {:ok, %{status: "cancelled"}} = MeetingQueries.get_meeting(meeting.id)
      assert_enqueued(@cancellation_email)
    end
  end

  describe "cancel_meeting_with_refund/3 by anyone else" do
    test "an attendee asking for a refund is refused before anything changes", %{
      attendee: attendee,
      meeting: meeting,
      payment: payment
    } do
      # Stubbed to succeed, so a refund that does not land was refused by the
      # rule and not by a missing mock.
      stub(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:ok, %{id: "re_should_not_happen"}}
      end)

      assert {:error, :not_found} =
               Meetings.cancel_meeting_with_refund(meeting, attendee.id, {:refund, 5000})

      assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.refunded_amount_cents == 0
      assert reloaded.status == "paid"

      refute_enqueued(worker: SendBookingPaymentRefunded)
    end

    test "an attendee cancelling without a refund still cancels", %{
      attendee: attendee,
      meeting: meeting,
      payment: payment
    } do
      assert {:ok, cancelled} = Meetings.cancel_meeting_with_refund(meeting, attendee.id, :none)
      assert cancelled.status == "cancelled"
      assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0
    end
  end
end
