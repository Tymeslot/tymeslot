defmodule Tymeslot.Bookings.OrchestratorPaidBookingTest do
  @moduledoc """
  Integration coverage for the paid-booking branch of
  `Tymeslot.Bookings.Orchestrator.submit_booking/2`.

  When a meeting type has `payment_required: true` and the host has a
  charges-enabled Stripe Connect account, the orchestrator should:

    * persist the meeting with status `awaiting_payment`,
    * create a booking_payment snapshot,
    * call Stripe Checkout via the StripeAdapter mock,
    * return `{:ok, :payment_required, %{meeting:, checkout_url:}}`.

  No emails or calendar jobs should be enqueued before payment.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 50
    )

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "host@example.com", name: "Host")
    {:ok, profile} = Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Profiles.update_profile(profile, %{timezone: "Europe/Berlin"})

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_HOST",
      default_currency: "eur",
      charges_enabled: true
    )

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Paid Consult",
        duration_minutes: 30,
        is_active: true,
        payment_required: true,
        price_cents: 5000
      )

    %{user: user, meeting_type: meeting_type}
  end

  describe "submit_booking/2 — paid event type" do
    test "returns :payment_required tuple, persists awaiting_payment meeting, no email/video jobs",
         %{user: user, meeting_type: meeting_type} do
      expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
        assert opts[:connect_account] == "acct_HOST"
        assert hd(params.line_items).price_data.currency == "eur"
        assert hd(params.line_items).price_data.unit_amount == 5000
        assert params.payment_intent_data.application_fee_amount == 25
        {:ok, %{id: "cs_TEST", url: "https://checkout.stripe.com/cs_TEST"}}
      end)

      params = %{
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        },
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "14:00",
          duration: "30min",
          user_timezone: "Europe/Berlin",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        }
      }

      assert {:ok, :payment_required, %{meeting: meeting, checkout_url: url}} =
               Orchestrator.submit_booking(params)

      assert url =~ "checkout.stripe.com"
      assert meeting.status == "awaiting_payment"
      assert meeting.attendee_email == "attendee@example.com"

      payment = BookingPaymentQueries.by_meeting_id(meeting.id)
      assert payment.status == "pending"
      assert payment.amount_cents == 5000
      assert payment.application_fee_cents == 25
      assert payment.currency == "eur"
      assert payment.stripe_checkout_session_id == "cs_TEST"

      refute_enqueued(worker: EmailWorker)
      refute_enqueued(worker: VideoRoomWorker)
    end

    test "expires the meeting, frees the slot, and returns a payment-oriented message when Stripe checkout creation fails",
         %{user: user, meeting_type: meeting_type} do
      # The Stripe call now runs outside the booking DB transaction, so the
      # meeting is no longer rolled back. Instead the orchestrator expires it on
      # checkout failure so the slot is released immediately.
      expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
        {:error, :stripe_unreachable}
      end)

      params = %{
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        },
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "16:00",
          duration: "30min",
          user_timezone: "Europe/Berlin",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        }
      }

      # The domain layer surfaces the semantic :checkout_failed atom — never
      # the DB-save fallback — and the web layer renders it to a
      # payment-oriented message.
      assert {:error, :checkout_failed} = Orchestrator.submit_booking(params)

      # The just-created meeting is expired (slot released), not left dangling
      # in awaiting_payment — so no awaiting_payment meeting remains for the host.
      assert MeetingQueries.count_awaiting_payment_for_organizer(user.id) == 0
    end

    test "returns the semantic :checkout_failed atom when Stripe returns a Stripe.Error struct",
         %{user: user, meeting_type: meeting_type} do
      # stripity_stripe returns {:error, %Stripe.Error{}} — a struct that is
      # neither a known atom nor a binary. `Create.classify_error/1` folds
      # any `{:checkout_failed, reason}` tuple (regardless of the inner
      # reason's shape) to the single `:checkout_failed` atom, so the
      # Stripe.Error internals (e.g. "Network timeout") never reach the
      # booker — the web layer renders a fixed payment-oriented message for
      # this atom.
      expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
        {:error,
         %{
           __struct__: Stripe.Error,
           source: :network,
           code: :network_error,
           message: "Network timeout"
         }}
      end)

      params = %{
        form_data: %{
          "name" => "Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        },
        meeting_params: %{
          date: Date.add(Date.utc_today(), 1),
          time: "17:00",
          duration: "30min",
          user_timezone: "Europe/Berlin",
          organizer_user_id: user.id,
          meeting_type_id: meeting_type.id
        }
      }

      assert {:error, :checkout_failed} = Orchestrator.submit_booking(params)

      assert MeetingQueries.count_awaiting_payment_for_organizer(user.id) == 0
    end
  end
end
