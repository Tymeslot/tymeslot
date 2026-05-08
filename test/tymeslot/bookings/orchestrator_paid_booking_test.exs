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
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.VideoRoomWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      payment_application_fee_bp: 50
    )

    TestMocks.setup_calendar_mocks()
    TestMocks.setup_email_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "host@example.com", name: "Host")
    {:ok, profile} = Tymeslot.Profiles.get_or_create_profile(user.id)
    {:ok, _profile} = Tymeslot.Profiles.update_profile(profile, %{timezone: "Europe/Berlin"})

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

    test "rolls back meeting when Stripe checkout creation fails",
         %{user: user, meeting_type: meeting_type} do
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

      assert {:error, _reason} = Orchestrator.submit_booking(params)
    end
  end
end
