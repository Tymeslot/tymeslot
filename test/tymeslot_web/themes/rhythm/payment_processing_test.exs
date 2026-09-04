defmodule TymeslotWeb.Themes.Rhythm.PaymentProcessingTest do
  @moduledoc """
  Mirrors the Quill processing-page contract for Rhythm: same
  authorisation rules, same broadcast-driven flip from "confirming" to
  "booking confirmed", same awaiting-approval/declined/expired outcomes
  for a paid gated booking, scoped to the Rhythm theme slug.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Phoenix.PubSub
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.Profiles

  setup do
    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: "2"})
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
      live(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")

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
      live(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")

    {:ok, _bp} =
      BookingPaymentQueries.update(bp, %{
        status: "paid",
        paid_at: DateTime.utc_now(:second)
      })

    PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting.id}", :paid)

    assert render(view) =~ "Booking confirmed"
  end

  test "renders the awaiting-approval request wording, not confirmed, for a paid gated booking",
       %{conn: conn, user: user} do
    deadline = DateTime.add(DateTime.utc_now(:second), 3600, :second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "awaiting_approval",
        approval_deadline_at: deadline
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: "paid",
      paid_at: DateTime.utc_now(:second),
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Payment received"
    refute html =~ "Booking confirmed"
  end

  test "renders the declined wording and mentions the refund for a declined gated booking", %{
    conn: conn,
    user: user
  } do
    now = DateTime.utc_now(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "cancelled",
        approval_resolved_at: now,
        approval_declined_at: now,
        decline_reason: "Can't make this time"
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: "refunded",
      paid_at: now,
      refunded_amount_cents: 5000,
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Booking not accepted"
    assert html =~ "refunded"
    refute html =~ "Booking confirmed"
    refute html =~ "Confirming your payment"
  end

  test "renders the expired wording and mentions the refund for a lapsed gated booking", %{
    conn: conn,
    user: user
  } do
    now = DateTime.utc_now(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        status: "expired",
        approval_resolved_at: now
      )

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: "refunded",
      paid_at: now,
      refunded_amount_cents: 5000,
      stripe_checkout_session_id: "cs_TEST"
    )

    {:ok, _view, html} =
      live(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")

    assert html =~ "Booking request expired"
    assert html =~ "refunded"
    refute html =~ "Booking confirmed"
    refute html =~ "Confirming your payment"
  end

  test "rejects mismatched session_id", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_REAL"
    )

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_FAKE")
  end

  test "rejects request when host uses Quill (theme mismatch)", %{conn: conn, user: user} do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{booking_theme: "1"})

    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_TEST"
    )

    assert {:error, {:redirect, _info}} =
             live(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")
  end

  test "dead render does not load page data", %{conn: conn, user: user} do
    meeting = insert(:meeting, organizer_user_id: user.id, status: "awaiting_payment")

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      stripe_checkout_session_id: "cs_TEST"
    )

    ref = make_ref()
    parent = self()
    handler_id = "rhythm-payment-processing-dead-render-#{inspect(ref)}"
    data_sources = ~w(meetings booking_payments)

    :telemetry.attach(
      handler_id,
      [:tymeslot, :repo, :query],
      fn _event, _measurements, %{source: source}, _config ->
        if source in data_sources, do: send(parent, {:db_query, ref, source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    get(conn, ~p"/themes/rhythm/payment-processing/#{meeting.id}?session_id=cs_TEST")

    refute_received {:db_query, ^ref, _source}, "Data-loading query fired during dead render"
  end
end
