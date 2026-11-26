defmodule Tymeslot.MeetingPayments.CheckoutSessionsSeatTest do
  # async: false: this suite mutates the global :feature_access_checker,
  # :meeting_payments_enabled and :payment_application_fee_bp application env.
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :payments

  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.MeetingPayments.SeatPaymentQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Profiles
  alias Tymeslot.SignedToken
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias TymeslotWeb.Endpoint

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 0
    )

    user = insert(:user)
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_booking_theme(profile, "1")

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_HOST",
      default_currency: "eur",
      charges_enabled: true
    )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Group Class",
        max_participants: 4,
        payment_required: true,
        price_cents: 2500
      )

    meeting =
      insert(:group_meeting,
        organizer_user_id: user.id,
        meeting_type_ref: meeting_type,
        capacity: 4,
        status: :awaiting_payment
      )

    %{user: user, meeting_type: meeting_type, meeting: meeting}
  end

  defp stripe_session(id \\ "cs_SEAT") do
    StripeFixtures.object("checkout_session_payment", %{
      "id" => id,
      "url" => "https://checkout.stripe.com/#{id}"
    })
  end

  # Opens the checkout, answered with `stripe_session/0`, and returns the
  # request it sent.
  defp checkout_request(hold) do
    StripeStub.expect(:create_checkout_session, stripe_session())
    result = Checkout.create_seat_checkout_session(hold)
    assert [request] = StripeStub.requests(:create_checkout_session)
    {result, request}
  end

  describe "create_seat_checkout_session/1" do
    test "a seat hold for three seats charges three times the price", %{meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, seats: 3, email: "a@example.com")

      assert {{:ok, %{checkout_url: "https://checkout.stripe.com/cs_SEAT", booking_payment: bp}},
              %{form: form}} = checkout_request(hold)

      assert [%{"price_data" => price_data, "quantity" => "3"}] = form["line_items"]
      assert price_data["unit_amount"] == "2500"
      assert price_data["product_data"]["name"] == "Group Class"

      assert bp.amount_cents == 7500
      assert bp.seats == 3
      assert bp.seat_payment
      assert bp.seat_hold_id == hold.id
      assert bp.meeting_id == meeting.id
      assert bp.participant_id == nil
      assert bp.status == :pending
      assert bp.stripe_checkout_session_id == "cs_SEAT"
    end

    test "the fee is calculated on the total", %{
      user: user,
      meeting: meeting,
      meeting_type: mt
    } do
      Application.put_env(:tymeslot, :payment_application_fee_bp, 50)
      mt |> Changeset.change(price_cents: 333) |> Repo.update!()
      hold = insert(:seat_hold, meeting: meeting, seats: 3, email: "a@example.com")

      # 0.5% of 9.99, rounded up to the cent; on one seat's 3.33 it would be 2.
      assert {{:ok, %{booking_payment: bp}}, %{form: form}} = checkout_request(hold)

      assert form["payment_intent_data"] == %{
               "application_fee_amount" => "5",
               "metadata" => %{
                 "seat_hold_id" => hold.id,
                 "meeting_id" => meeting.id,
                 "host_user_id" => to_string(user.id)
               }
             }

      assert bp.amount_cents == 999
      assert bp.application_fee_cents == 5
    end

    test "the session carries the hold's booker, not the meeting's", %{
      user: user,
      meeting: meeting
    } do
      meeting =
        meeting
        |> Changeset.change(
          attendee_email: "first@example.com",
          attendee_name: "First",
          attendee_locale: "en"
        )
        |> Repo.update!()

      hold =
        insert(:seat_hold, meeting: meeting, email: "b@example.com", name: "Bea", locale: "de")

      assert {{:ok, %{booking_payment: bp}}, %{form: form}} = checkout_request(hold)
      assert form["customer_email"] == "b@example.com"
      assert form["locale"] == "de"
      assert form["client_reference_id"] == "seat_hold:" <> hold.id

      assert form["payment_intent_data"]["metadata"] == %{
               "seat_hold_id" => hold.id,
               "meeting_id" => meeting.id,
               "host_user_id" => to_string(user.id)
             }

      assert bp.attendee_email == "b@example.com"
      assert bp.attendee_name == "Bea"
    end

    test "the session expires 30 minutes after it is created, before its hold", %{
      meeting: meeting
    } do
      hold_expires_at = DateTime.add(DateTime.utc_now(:second), 35, :minute)

      hold =
        insert(:seat_hold, meeting: meeting, email: "a@example.com", expires_at: hold_expires_at)

      assert {{:ok, _result}, %{form: %{"expires_at" => expires_at}}} = checkout_request(hold)
      expires_at = String.to_integer(expires_at)
      assert_in_delta expires_at, System.os_time(:second) + 30 * 60, 5
      assert expires_at < DateTime.to_unix(hold_expires_at)
    end

    test "the idempotency key and return pages come from the hold", %{meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")
      base = Endpoint.url() <> "/themes/quill"

      assert {{:ok, _result}, %{form: form, headers: headers}} = checkout_request(hold)
      assert headers["idempotency-key"] == "tymeslot:seat_checkout:#{hold.id}"
      assert headers["stripe-account"] == "acct_HOST"

      assert form["success_url"] ==
               "#{base}/payment-processing/seat/#{hold.id}?session_id={CHECKOUT_SESSION_ID}"

      assert %URI{path: path, query: query} = URI.parse(form["cancel_url"])
      assert path == "/themes/quill/payment-cancelled/seat/#{hold.id}"
      assert %{"return_token" => token} = URI.decode_query(query)
      assert Checkout.returned_from_seat_checkout?(hold.id, token)
      refute Checkout.returned_from_checkout?(hold.id, token)
    end

    test "a hold that would lapse before its session is refused", %{meeting: meeting} do
      hold =
        insert(:seat_hold,
          meeting: meeting,
          email: "a@example.com",
          expires_at: DateTime.add(DateTime.utc_now(:second), 29, :minute)
        )

      # Nothing is stubbed, so any Stripe call fails the test.
      assert {:error, :hold_expired} = Checkout.create_seat_checkout_session(hold)
      assert SeatPaymentQueries.by_seat_hold_id(hold.id) == nil
    end

    test "a released hold is refused", %{meeting: meeting} do
      hold =
        insert(:seat_hold,
          meeting: meeting,
          email: "a@example.com",
          status: :released,
          released_reason: :abandoned
        )

      assert {:error, :hold_expired} = Checkout.create_seat_checkout_session(hold)
      assert SeatPaymentQueries.by_seat_hold_id(hold.id) == nil
    end

    test "a hold already converted to a seat is refused", %{meeting: meeting} do
      participant = insert(:participant, meeting: meeting, email: "a@example.com")

      hold =
        insert(:seat_hold,
          meeting: meeting,
          email: "a@example.com",
          status: :converted,
          participant_id: participant.id
        )

      assert {:error, :hold_expired} = Checkout.create_seat_checkout_session(hold)
      assert SeatPaymentQueries.by_seat_hold_id(hold.id) == nil
    end

    test "a host without payments access cannot open a seat checkout", %{meeting: meeting} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      assert {:error, :payments_unavailable} = Checkout.create_seat_checkout_session(hold)
      assert SeatPaymentQueries.by_seat_hold_id(hold.id) == nil
    end

    test "a type no longer paid opens no checkout", %{meeting: meeting, meeting_type: mt} do
      mt |> Changeset.change(payment_required: false) |> Repo.update!()
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      assert {:error, :payment_not_required} = Checkout.create_seat_checkout_session(hold)
      assert SeatPaymentQueries.by_seat_hold_id(hold.id) == nil
    end
  end

  describe "returned_from_seat_checkout?/2" do
    test "accepts only a token signed for that hold's checkout" do
      hold_id = UUID.generate()

      assert Checkout.returned_from_seat_checkout?(
               hold_id,
               SignedToken.sign(:seat_checkout_return, hold_id)
             )

      refute Checkout.returned_from_seat_checkout?(
               hold_id,
               SignedToken.sign(:seat_checkout_return, UUID.generate())
             )

      refute Checkout.returned_from_seat_checkout?(
               hold_id,
               SignedToken.sign(:checkout_return, hold_id)
             )

      refute Checkout.returned_from_seat_checkout?(hold_id, nil)
    end
  end

  describe "abandon_seat_checkout/1" do
    test "expires the open session", %{user: user, meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      insert(:booking_payment,
        meeting: meeting,
        seat_hold_id: hold.id,
        seat_payment: true,
        host_user_id: user.id,
        stripe_account_id: "acct_HOST",
        stripe_checkout_session_id: "cs_OPEN"
      )

      StripeStub.expect(
        :expire_checkout_session,
        StripeFixtures.object("checkout_session_expired", %{"id" => "cs_OPEN"})
      )

      assert :ok = Checkout.abandon_seat_checkout(hold.id)

      assert [%{path: path, headers: %{"stripe-account" => "acct_HOST"}}] =
               StripeStub.requests(:expire_checkout_session)

      assert path =~ "cs_OPEN"

      # The hold is released by the `checkout.session.expired` webhook.
      assert SeatHolds.get(hold.id).status == :held
    end

    # Nothing is stubbed, so any Stripe call fails the cases below.
    test "is :ok for a hold with no payment", %{meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      assert :ok = Checkout.abandon_seat_checkout(hold.id)
    end

    test "is :ok for a malformed hold id" do
      assert :ok = Checkout.abandon_seat_checkout("not-a-uuid")
    end

    test "is :ok for a hold whose payment is settled", %{user: user, meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      insert(:booking_payment,
        meeting: meeting,
        seat_hold_id: hold.id,
        seat_payment: true,
        host_user_id: user.id,
        status: :paid,
        stripe_checkout_session_id: "cs_PAID"
      )

      assert :ok = Checkout.abandon_seat_checkout(hold.id)
    end
  end
end
