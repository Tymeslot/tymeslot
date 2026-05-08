defmodule TymeslotWeb.Themes.Quill.PaymentProcessingTest do
  @moduledoc """
  Covers the Quill `payment-processing` return page reached after a
  successful Stripe Checkout redirect.

  Locks in:
    * the processing UI when the payment is still pending,
    * the confirmed UI once the webhook has marked the row paid,
    * authorisation: rejecting a session_id that doesn't match the
      stored Checkout Session id (cross-meeting probing),
    * authorisation: rejecting a request whose URL slug doesn't match
      the host's configured booking_theme.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  setup do
    user = insert(:user)
    {:ok, profile} = Tymeslot.Profiles.get_or_create_profile(user.id)
    {:ok, profile} = Tymeslot.Profiles.update_profile(profile, %{booking_theme: "1"})

    %{user: user, profile: profile}
  end

  test "renders processing UI when payment still pending", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Confirming your payment"
  end

  test "flips to confirmation UI when broadcast says paid", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    bp =
      insert(:booking_payment,
        meeting: meeting,
        host_user_id: user.id,
        status: "pending",
        stripe_checkout_session_id: "cs_TEST"
      )

    {:ok, view, _html} =
      live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")

    # Flip the row to paid (simulating the webhook side effect) and broadcast
    {:ok, _bp} =
      Tymeslot.MeetingPayments.BookingPaymentQueries.update(bp, %{
        status: "paid",
        paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    Phoenix.PubSub.broadcast(
      Tymeslot.PubSub,
      "meeting_payment:#{meeting.id}",
      :paid
    )

    assert render(view) =~ "Booking confirmed"
  end

  test "rejects mismatched session_id", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_REAL"
    )

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_FAKE")
  end

  test "rejects mismatched theme slug (host uses Rhythm)", %{conn: conn, user: user} do
    {:ok, profile} = Tymeslot.Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Tymeslot.Profiles.update_profile(profile, %{booking_theme: "2"})

    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_TEST"
    )

    assert {:error, {:redirect, _info}} =
             live(conn, ~p"/themes/quill/payment-processing/#{meeting.id}?session_id=cs_TEST")
  end
end
