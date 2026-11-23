defmodule TymeslotWeb.Dashboard.BookingsManagementCancelRefundTest do
  @moduledoc """
  The paid-booking cancel dialog when a submit is refused: the choice, amount
  and acknowledgement are the host's until submit, so a re-render without them
  would snap the choice back to a full refund. And a payment past the refund
  window, or under dispute: the dialog says up front that cancelling will
  not refund it, and the cancellation goes through without one, saying why.
  And the ordinary choices: a full refund, and no refund only once the host
  acknowledges it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "a refused partial amount stays a partial refund, with the amount beside the error",
       %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Paid Partial"
      )

    payment =
      insert(:booking_payment,
        meeting_id: meeting.id,
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_PAID4",
        stripe_charge_id: "ch_PAID_#{System.unique_integer([:positive])}",
        amount_cents: 5000,
        application_fee_cents: 25,
        currency: "eur",
        status: :paid,
        paid_at: DateTime.utc_now(:second),
        refunded_amount_cents: 0
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

    view
    |> form("#cancel-meeting-form", %{
      "cancel_refund_choice" => "partial",
      "cancel_refund_amount" => "999.00"
    })
    |> render_submit()

    assert has_element?(view, "input[name=cancel_refund_choice][value=partial][checked]")
    refute has_element?(view, "input[name=cancel_refund_choice][value=full][checked]")
    assert has_element?(view, "input[name=cancel_refund_amount][value='999.00']")
    assert has_element?(view, "#cancel-meeting-form [role=alert]", "exceeds the remaining")
    refute has_element?(view, "#cancel-refund-ack-error")
    assert Repo.get(MeetingSchema, meeting.id).status == :confirmed
    assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0
  end

  describe "cancelling a paid booking" do
    setup :verify_on_exit!

    setup do
      stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email,
                                                                                _details ->
        {:ok, nil}
      end)

      stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
        {:ok, nil}
      end)

      :ok
    end

    test "cancelling a paid booking with full refund issues the refund and cancels",
         %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Paid Customer"
        )

      payment =
        insert(:booking_payment,
          meeting_id: meeting.id,
          host_user_id: user.id,
          host_email: user.email,
          stripe_account_id: "acct_PAID",
          stripe_charge_id: "ch_PAID_#{System.unique_integer([:positive])}",
          amount_cents: 5000,
          application_fee_cents: 25,
          currency: "eur",
          status: :paid,
          paid_at: DateTime.utc_now(:second),
          refunded_amount_cents: 0
        )

      StripeStub.expect(:create_refund, 1, fn request ->
        assert request.form["amount"] == "5000"
        StripeStubResponses.refund(request, "re_cancel_full")
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      assert render(view) =~ "Meeting cancelled and refund issued"

      updated = BookingPaymentQueries.get(payment.id)
      assert updated.status == :refunded
      assert updated.refunded_amount_cents == 5000

      assert Repo.get(MeetingSchema, meeting.id).status == :cancelled
    end

    test "cancelling with a refund that is still pending cancels and says so",
         %{conn: conn, user: user} do
      {meeting, payment} = paid_meeting(user, "Pending Refund")

      # The client sends the lost call 3 times in all, under the same key.
      StripeStub.expect(:create_refund, 3, {:transport_error, :timeout})

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      html = render(view)

      assert html =~
               "Meeting cancelled. The refund is being processed and the attendee will be emailed when it goes through."

      refute html =~ "Stripe dashboard"
      assert Repo.get(MeetingSchema, meeting.id).status == :cancelled
      assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0

      assert [%{source: :cancellation, status: :pending}] =
               RefundQueries.list_for_payment(payment.id)
    end

    test "a declined cancellation refund keeps the meeting cancelled and points to Stripe",
         %{conn: conn, user: user} do
      {meeting, payment} = paid_meeting(user, "Declined Refund")

      StripeStub.expect(:create_refund, {:error_fixture, "invalid_request_error"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      assert render(view) =~
               "Meeting cancelled, but Stripe declined the refund. Check the payment in your Stripe dashboard."

      assert Repo.get(MeetingSchema, meeting.id).status == :cancelled
      assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0
    end

    # Recorded from the payments page after the dialog opened: the refund the
    # dialog offered no longer fits, and Stripe is never asked.
    test "a refund the payment no longer allows keeps the meeting cancelled and says why",
         %{conn: conn, user: user} do
      {meeting, payment} = paid_meeting(user, "Raced Refund")
      StripeStub.stub(:create_refund, {:error_fixture, "api_error"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2000)

      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
      |> render_submit()

      html = render(view)

      assert html =~
               "Cancelled without a refund: the payment&#39;s refundable balance changed meanwhile. Check it on the payments page."

      refute html =~ "Stripe declined"
      assert StripeStub.requests(:create_refund) == []
      assert Repo.get(MeetingSchema, meeting.id).status == :cancelled
    end

    test "the dialog says when a refund of the booking is already being processed",
         %{conn: conn, user: user} do
      {meeting, payment} = paid_meeting(user, "Partly Pending")
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2000)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      assert has_element?(
               view,
               "#cancel-meeting-pending-refund",
               "A refund of €20.00 is already being processed."
             )

      assert has_element?(view, "#cancel-meeting-form", "Refunds the remaining balance (€30.00).")
    end

    test "cancelling a paid booking without refund requires the acknowledgement",
         %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Paid Customer"
        )

      payment =
        insert(:booking_payment,
          meeting_id: meeting.id,
          host_user_id: user.id,
          host_email: user.email,
          stripe_account_id: "acct_PAID2",
          stripe_charge_id: "ch_PAID_#{System.unique_integer([:positive])}",
          amount_cents: 5000,
          application_fee_cents: 25,
          currency: "eur",
          status: :paid,
          paid_at: DateTime.utc_now(:second),
          refunded_amount_cents: 0
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      # No acknowledgement: must error and leave meeting confirmed.
      view
      |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "none"})
      |> render_submit()

      assert has_element?(view, "#cancel-refund-ack-error", "Tick the acknowledgement")
      # The choice survives the refusal: snapping back to Full would refund.
      assert has_element?(view, "input[name=cancel_refund_choice][value=none][checked]")
      refute has_element?(view, "input[name=cancel_refund_choice][value=full][checked]")
      assert Repo.get(MeetingSchema, meeting.id).status == :confirmed

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == :paid
      assert reloaded.refunded_amount_cents == 0
    end

    test "cancelling a paid booking without refund acks succeeds without calling Stripe",
         %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Paid No Refund"
        )

      payment =
        insert(:booking_payment,
          meeting_id: meeting.id,
          host_user_id: user.id,
          host_email: user.email,
          stripe_account_id: "acct_PAID3",
          stripe_charge_id: "ch_PAID_#{System.unique_integer([:positive])}",
          amount_cents: 5000,
          application_fee_cents: 25,
          currency: "eur",
          status: :paid,
          paid_at: DateTime.utc_now(:second),
          refunded_amount_cents: 0
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      view
      |> form("#cancel-meeting-form", %{
        "cancel_refund_choice" => "none",
        "cancel_refund_no_refund_ack" => "true"
      })
      |> render_submit()

      assert render(view) =~ "Meeting cancelled successfully"
      assert Repo.get(MeetingSchema, meeting.id).status == :cancelled

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == :paid
      assert reloaded.refunded_amount_cents == 0
    end
  end

  describe "a payment past the refund window" do
    setup :verify_on_exit!

    setup %{user: user} do
      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          attendee_name: "Paid Long Ago"
        )

      payment =
        insert(:booking_payment,
          meeting_id: meeting.id,
          host_user_id: user.id,
          host_email: user.email,
          stripe_account_id: "acct_OLD",
          stripe_charge_id: "ch_OLD_#{System.unique_integer([:positive])}",
          amount_cents: 5000,
          application_fee_cents: 25,
          currency: "eur",
          status: :paid,
          paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day),
          refunded_amount_cents: 0
        )

      %{meeting: meeting, payment: payment}
    end

    test "is cancelled without a refund, and the host is told why first and after",
         %{conn: conn, meeting: meeting, payment: payment} do
      StripeStub.stub(:create_refund, StripeStubResponses.refund("re_must_not_happen"))

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

      refute has_element?(view, "input[name=cancel_refund_choice]")

      assert has_element?(
               view,
               "#cancel-meeting-form",
               "Cancelling won't refund the attendee: the payment is older than the 60-day refund window."
             )

      view |> form("#cancel-meeting-form", %{}) |> render_submit()
      html = render(view)

      assert html =~
               "Cancelled without a refund: the payment is older than the 60-day refund window."

      refute html =~ "refund could not be issued"
      assert Repo.get(MeetingSchema, meeting.id).status == :cancelled
      assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0
      assert StripeStub.requests(:create_refund) == []
    end

    # The dialog offers no amount for such a payment; one sent anyway is
    # refused before anything is cancelled.
    test "an explicit amount is refused before anything is cancelled", %{payment: payment} do
      params = %{"cancel_refund_choice" => "partial", "cancel_refund_amount" => "10.00"}

      assert {:error, :outside_refund_window} =
               Meetings.resolve_cancellation_refund(payment, params)

      assert {:ok, {:not_refunded, :outside_refund_window}} =
               Meetings.resolve_cancellation_refund(payment, %{})
    end
  end

  # A disputed payment is not one the host still owes from here: Stripe
  # holds the money. The dialog still says why cancelling refunds nothing.
  test "a disputed payment's dialog says cancelling won't refund it",
       %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Paid Disputed"
      )

    insert(:booking_payment,
      meeting_id: meeting.id,
      host_user_id: user.id,
      host_email: user.email,
      stripe_account_id: "acct_DISPUTED",
      stripe_charge_id: "ch_DISPUTED_#{System.unique_integer([:positive])}",
      amount_cents: 5000,
      application_fee_cents: 25,
      currency: "eur",
      status: :disputed,
      paid_at: DateTime.utc_now(:second),
      refunded_amount_cents: 0
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

    refute has_element?(view, "input[name=cancel_refund_choice]")

    assert has_element?(
             view,
             "#cancel-meeting-form",
             "Cancelling won't refund the attendee: the payment is under dispute. Settle the dispute in Stripe first."
           )
  end

  # Each refusal is one whole sentence to translate, never a fragment
  # joined to a lead-in, so a language can build it its own way.
  test "a host working in German reads the warning as one sentence", %{conn: conn} do
    host = insert(:user, onboarding_completed_at: DateTime.utc_now(), locale: "de")
    insert(:profile, user: host)
    conn = log_in_user(conn, host)

    meeting =
      insert(:meeting,
        organizer_user_id: host.id,
        organizer_email: host.email,
        attendee_name: "Paid Disputed"
      )

    insert(:booking_payment,
      meeting_id: meeting.id,
      host_user_id: host.id,
      host_email: host.email,
      stripe_account_id: "acct_DISPUTED_DE",
      stripe_charge_id: "ch_DISPUTED_DE_#{System.unique_integer([:positive])}",
      amount_cents: 5000,
      application_fee_cents: 25,
      currency: "eur",
      status: :disputed,
      paid_at: DateTime.utc_now(:second),
      refunded_amount_cents: 0
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

    assert has_element?(
             view,
             "#cancel-meeting-form",
             "Die Absage erstattet dem Teilnehmer nichts, da die Zahlung angefochten wird. Klären Sie die Anfechtung zuerst in Stripe."
           )
  end

  defp paid_meeting(user, attendee_name) do
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: attendee_name
      )

    payment =
      insert(:paid_booking_payment,
        meeting_id: meeting.id,
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_CANCEL"
      )

    {meeting, payment}
  end
end
