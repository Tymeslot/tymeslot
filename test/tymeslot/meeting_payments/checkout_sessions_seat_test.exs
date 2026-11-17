defmodule Tymeslot.MeetingPayments.CheckoutSessionsSeatTest do
  # async: false: this suite mutates the global :feature_access_checker,
  # :meeting_payments_enabled and :payment_application_fee_bp application env.
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :payments

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.ApplicationFee
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Profiles
  alias Tymeslot.SignedToken
  alias TymeslotWeb.Endpoint

  setup :verify_on_exit!

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
    {:ok, %{id: id, url: "https://checkout.stripe.com/#{id}", payment_intent: "pi_SEAT"}}
  end

  describe "create_seat_checkout_session/1" do
    test "a seat hold for three seats charges three times the price", %{meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, seats: 3, email: "a@example.com")

      expect(StripeAdapterMock, :create_checkout_session, fn params, _opts ->
        assert [%{price_data: price_data, quantity: 3}] = params.line_items
        assert price_data.unit_amount == 2500
        assert price_data.product_data.name == "Group Class"
        stripe_session()
      end)

      assert {:ok, %{checkout_url: "https://checkout.stripe.com/cs_SEAT", booking_payment: bp}} =
               MeetingPayments.create_seat_checkout_session(hold)

      assert bp.amount_cents == 7500
      assert bp.seats == 3
      assert bp.seat_payment
      assert bp.seat_hold_id == hold.id
      assert bp.meeting_id == meeting.id
      assert bp.participant_id == nil
      assert bp.status == :pending
      assert bp.stripe_checkout_session_id == "cs_SEAT"
    end

    test "the fee is calculated on the total", %{meeting: meeting, meeting_type: mt} do
      Application.put_env(:tymeslot, :payment_application_fee_bp, 50)
      mt |> Changeset.change(price_cents: 333) |> Repo.update!()
      hold = insert(:seat_hold, meeting: meeting, seats: 3, email: "a@example.com")
      expected_fee = ApplicationFee.calculate(999, 50)

      expect(StripeAdapterMock, :create_checkout_session, fn params, _opts ->
        assert params.payment_intent_data.application_fee_amount == expected_fee
        stripe_session()
      end)

      assert {:ok, %{booking_payment: bp}} = MeetingPayments.create_seat_checkout_session(hold)
      assert bp.amount_cents == 999
      assert bp.application_fee_cents == expected_fee
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

      expect(StripeAdapterMock, :create_checkout_session, fn params, _opts ->
        assert params.customer_email == "b@example.com"
        assert params.locale == "de"
        assert params.client_reference_id == "seat_hold:" <> hold.id

        assert params.payment_intent_data.metadata == %{
                 seat_hold_id: hold.id,
                 meeting_id: meeting.id,
                 host_user_id: user.id
               }

        stripe_session()
      end)

      assert {:ok, %{booking_payment: bp}} = MeetingPayments.create_seat_checkout_session(hold)
      assert bp.attendee_email == "b@example.com"
      assert bp.attendee_name == "Bea"
    end

    test "the idempotency key and expiry come from the hold", %{meeting: meeting} do
      expires_at = DateTime.add(DateTime.utc_now(:second), 17, :minute)
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com", expires_at: expires_at)
      base = Endpoint.url() <> "/themes/quill"

      expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
        assert opts[:idempotency_key] == "checkout:seat_hold:#{hold.id}"
        assert opts[:connect_account] == "acct_HOST"
        assert params.expires_at == DateTime.to_unix(expires_at)

        assert params.success_url ==
                 "#{base}/payment-processing/seat/#{hold.id}?session_id={CHECKOUT_SESSION_ID}"

        assert %URI{path: path, query: query} = URI.parse(params.cancel_url)
        assert path == "/themes/quill/payment-cancelled/seat/#{hold.id}"
        assert %{"return_token" => token} = URI.decode_query(query)
        assert MeetingPayments.returned_from_seat_checkout?(hold.id, token)
        refute MeetingPayments.returned_from_checkout?(hold.id, token)

        stripe_session()
      end)

      assert {:ok, _result} = MeetingPayments.create_seat_checkout_session(hold)
    end

    test "a hold about to lapse is refused", %{meeting: meeting} do
      hold =
        insert(:seat_hold,
          meeting: meeting,
          email: "a@example.com",
          expires_at: DateTime.add(DateTime.utc_now(:second), 30, :second)
        )

      # Mox raises on any call to the adapter here.
      assert {:error, :hold_expired} = MeetingPayments.create_seat_checkout_session(hold)
      assert BookingPaymentQueries.by_seat_hold_id(hold.id) == nil
    end

    test "a host without payments access cannot open a seat checkout", %{meeting: meeting} do
      Application.put_env(:tymeslot, :meeting_payments_enabled, false)
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      assert {:error, :payments_unavailable} = MeetingPayments.create_seat_checkout_session(hold)
      assert BookingPaymentQueries.by_seat_hold_id(hold.id) == nil
    end

    test "a type no longer paid opens no checkout", %{meeting: meeting, meeting_type: mt} do
      mt |> Changeset.change(payment_required: false) |> Repo.update!()
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      assert {:error, :payment_not_required} = MeetingPayments.create_seat_checkout_session(hold)
      assert BookingPaymentQueries.by_seat_hold_id(hold.id) == nil
    end
  end

  describe "returned_from_seat_checkout?/2" do
    test "accepts only a token signed for that hold's checkout" do
      hold_id = UUID.generate()

      assert MeetingPayments.returned_from_seat_checkout?(
               hold_id,
               SignedToken.sign(:seat_checkout_return, hold_id)
             )

      refute MeetingPayments.returned_from_seat_checkout?(
               hold_id,
               SignedToken.sign(:seat_checkout_return, UUID.generate())
             )

      refute MeetingPayments.returned_from_seat_checkout?(
               hold_id,
               SignedToken.sign(:checkout_return, hold_id)
             )

      refute MeetingPayments.returned_from_seat_checkout?(hold_id, nil)
    end
  end

  describe "abandon_seat_checkout/1" do
    test "abandon_seat_checkout expires the open session", %{user: user, meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      insert(:booking_payment,
        meeting: meeting,
        seat_hold_id: hold.id,
        seat_payment: true,
        host_user_id: user.id,
        stripe_account_id: "acct_HOST",
        stripe_checkout_session_id: "cs_OPEN"
      )

      expect(StripeAdapterMock, :expire_checkout_session, fn "cs_OPEN", opts ->
        assert opts[:connect_account] == "acct_HOST"
        {:ok, %{id: "cs_OPEN", status: "expired"}}
      end)

      assert :ok = MeetingPayments.abandon_seat_checkout(hold.id)

      # The hold is released by the `checkout.session.expired` webhook.
      assert SeatHolds.get(hold.id).status == :held
    end

    test "abandon_seat_checkout is :ok when nothing is open", %{user: user, meeting: meeting} do
      hold = insert(:seat_hold, meeting: meeting, email: "a@example.com")

      assert :ok = MeetingPayments.abandon_seat_checkout(hold.id)
      assert :ok = MeetingPayments.abandon_seat_checkout("not-a-uuid")

      insert(:booking_payment,
        meeting: meeting,
        seat_hold_id: hold.id,
        seat_payment: true,
        host_user_id: user.id,
        status: :paid,
        stripe_checkout_session_id: "cs_PAID"
      )

      # Mox raises on any call to the adapter here.
      assert :ok = MeetingPayments.abandon_seat_checkout(hold.id)
    end
  end
end
