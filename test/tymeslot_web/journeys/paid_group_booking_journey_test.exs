defmodule TymeslotWeb.Journeys.PaidGroupBookingJourneyTest do
  @moduledoc """
  Paid group sessions as the people using them meet them, end to end: two
  bookers pay for seats and the host cancels with refunds; a booker who
  never pays gives their seats back; a payment arriving after the slot
  filled is refunded; a participant who leaves is owed their money by the
  host; and a paid seat moves to another session with its payment.

  Bookers book through the booking page (`BookingDriver`), and every
  payment outcome arrives as a signed Stripe webhook posted to the
  connected-account endpoint, decoded and verified as in production.
  Mocked are the boundaries only: the calendar provider and Stripe. Emails
  are rendered by the real email service and delivered to this process.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2, where: 3]
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.BookingTestHelpers, only: [walk_from_schedule_to_booking_form: 2]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.PaymentTestHelpers
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.StripeWebhookFixtures
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @quill "1"
  @account "acct_PAID_GROUP"
  @secret "whsec_paid_group_journey"
  @price 2000

  @ada %{name: "Ada Lovelace", email: "ada@example.com"}
  @ben %{name: "Ben Franklin", email: "ben@example.com"}

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 50,
      stripe_connect_webhook_secret: @secret
    )

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))

    TestMocks.setup_all_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    # A completed checkout looks up its charge, which a refund needs.
    StripeStub.stub(:retrieve_payment_intent, fn %{path: path} ->
      intent_id = last_segment(path)
      StripeStubResponses.payment_intent(intent_id, "ch_" <> intent_id)
    end)

    # A paid seat's confirmation links the charge's receipt.
    StripeStub.stub(:retrieve_charge, fn %{path: path} ->
      charge_id = last_segment(path)

      StripeFixtures.object("charge", %{
        "id" => charge_id,
        "receipt_url" => "https://pay.stripe.com/receipts/" <> charge_id
      })
    end)

    # The real email service, so the rendered emails reach this process.
    email_service = Application.get_env(:tymeslot, :email_service_module)
    Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, recaptcha)
      Application.put_env(:tymeslot, :email_service_module, email_service)
      Application.delete_env(:swoosh, :shared_test_process)
    end)

    %{day: Date.utc_today() |> Date.add(1) |> Date.to_iso8601()}
  end

  # An organiser on Quill with one paid group type, "Group Class", of
  # `capacity` places at €20.00 a seat, which names the spots left on each
  # slot, guests allowed, and a Stripe account in euros.
  defp organiser(username, capacity) do
    %{user: user, profile: profile} =
      seed_organiser(@quill, username,
        types: [
          [
            name: "Group Class",
            duration_minutes: 30,
            max_participants: capacity,
            allow_guests: true,
            payment_required: true,
            price_cents: @price,
            last_spots_threshold: capacity
          ]
        ]
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: @account,
      default_currency: "eur",
      charges_enabled: true,
      payouts_enabled: true,
      details_submitted: true
    )

    %{user: user, profile: profile}
  end

  # Opens the booking page on the type's first time on `day`, at the form.
  # Returns the view and the time picked.
  defp open_form(conn, profile, day) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.choose_meeting_type(view, "group-class")
    {^day, time} = BookingDriver.pick_first_slot(view, on: day)
    to_form(view)
    {view, time}
  end

  defp to_form(view) do
    unless has_element?(view, "form[data-fact='attendee']"), do: BookingDriver.continue(view)
    view
  end

  defp add_guest(view, email) do
    unless has_element?(view, "#guest-add-form") do
      view |> element("[data-testid='guest-toggle']") |> render_click()
    end

    view |> form("#guest-add-form", %{"guest_email" => email}) |> render_submit()
  end

  # Submits the booking form and follows the page out to Stripe Checkout,
  # whose session the mock opens as `session_id` for `seats` seats.
  defp pay_at_checkout(view, booker, session_id, seats) do
    StripeStub.expect(:create_checkout_session, fn %{form: form, headers: headers} ->
      assert headers["stripe-account"] == @account

      assert [%{"quantity" => quantity, "price_data" => %{"unit_amount" => unit_amount}}] =
               form["line_items"]

      assert String.to_integer(quantity) == seats
      assert String.to_integer(unit_amount) == @price

      StripeFixtures.object("checkout_session_payment", %{
        "id" => session_id,
        "url" => "https://checkout.stripe.com/c/pay/#{session_id}"
      })
    end)

    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => booker.name, "email" => booker.email, "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, "https://checkout.stripe.com/c/pay/#{session_id}", 5_000)

    hold = Repo.get_by!(SeatHoldSchema, email: booker.email, status: :held)
    payment = Repo.get_by!(BookingPaymentSchema, seat_hold_id: hold.id)
    assert payment.amount_cents == @price * seats
    {hold, payment}
  end

  defp completed(conn, payment) do
    post_webhook(conn, payment, "checkout.session.completed", %{
      "payment_intent" => "pi_#{payment.id}",
      "payment_status" => "paid",
      "status" => "complete",
      "amount_total" => payment.amount_cents,
      "currency" => payment.currency
    })
  end

  defp expired(conn, payment) do
    post_webhook(conn, payment, "checkout.session.expired", %{
      "payment_intent" => nil,
      "payment_status" => "unpaid",
      "status" => "expired"
    })
  end

  # Posts the checkout session event Stripe sends for `payment`'s session,
  # signed under the connected-account endpoint's secret. The completed
  # fixture is the fullest session payload, so `type` is overridden for the
  # other events.
  defp post_webhook(conn, payment, type, object) do
    body =
      StripeWebhookFixtures.body(
        "checkout.session.completed",
        Map.merge(
          %{
            "id" => payment.stripe_checkout_session_id,
            "client_reference_id" => "seat_hold:" <> payment.seat_hold_id,
            "metadata" => %{"seat_hold_id" => payment.seat_hold_id}
          },
          object
        ),
        %{
          "id" => "evt_#{System.unique_integer([:positive])}",
          "type" => type,
          "account" => @account,
          "created" => System.os_time(:second)
        }
      )

    conn
    |> recycle()
    |> put_req_header("content-type", "application/json")
    |> put_req_header(
      "stripe-signature",
      PaymentTestHelpers.generate_stripe_signature(body, @secret)
    )
    |> post("/webhooks/stripe/connect", body)
    |> response(200)
  end

  defp dashboard(user) do
    user
    |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    build_conn() |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
  end

  # Runs every email job due and returns the emails they sent.
  defp deliver_emails do
    Oban.drain_queue(queue: :emails, with_recursion: true)
    mailbox([])
  end

  defp mailbox(emails) do
    receive do
      {:email, email} -> mailbox([email | emails])
    after
      0 -> Enum.reverse(emails)
    end
  end

  defp sent_to(emails, address),
    do: Enum.filter(emails, fn email -> Enum.any?(email.to, &(elem(&1, 1) == address)) end)

  defp live_participants(meeting_id) do
    ParticipantSchema
    |> where([p], p.meeting_id == ^meeting_id and is_nil(p.cancelled_at))
    |> Repo.all()
  end

  defp seat_of(email), do: Repo.get_by!(ParticipantSchema, email: email)

  @tag :capture_log
  test "two bookers pay for seats and the host cancels with refunds",
       %{conn: conn, day: day} do
    %{user: host, profile: profile} = organiser("paid-group-cancel", 4)

    # Ada books herself and a guest: one checkout for two seats.
    {view, _time} = open_form(conn, profile, day)
    add_guest(view, "grace@example.com")
    {ada_hold, ada_payment} = pay_at_checkout(view, @ada, "cs_ADA", 2)

    assert Repo.get!(MeetingSchema, ada_hold.meeting_id).status == :awaiting_payment

    completed(conn, ada_payment)

    session = Repo.get!(MeetingSchema, ada_hold.meeting_id)
    assert session.status == :confirmed
    assert [%{email: "ada@example.com"}] = live_participants(session.id)

    assert [confirmation] = sent_to(deliver_emails(), @ada.email)
    assert confirmation.text_body =~ "For 2 seats"

    # Ben books the same session alone and pays.
    {view, _time} = open_form(build_conn(), profile, day)
    {ben_hold, ben_payment} = pay_at_checkout(view, @ben, "cs_BEN", 1)
    assert ben_hold.meeting_id == session.id
    completed(conn, ben_payment)

    assert session.id |> live_participants() |> Enum.map(& &1.email) |> Enum.sort() ==
             [@ada.email, @ben.email]

    _confirmations = deliver_emails()

    # The host cancels the session from the bookings page, refunding everyone.
    {:ok, bookings, _html} = live(dashboard(host), ~p"/dashboard/meetings")
    bookings |> element("#cancel-meeting-#{session.id}") |> render_click()

    bookings
    |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
    |> render_submit()

    assert Repo.get!(MeetingSchema, session.id).status == :cancelled
    assert length(cancellation_refunds()) == 2

    StripeStub.expect(:create_refund, 2, fn %{form: form} = request ->
      StripeStubResponses.refund(request, "re_" <> form["charge"])
    end)

    assert %{failure: 0, success: 2} = Oban.drain_queue(queue: :payments, with_scheduled: true)

    assert %{status: :refunded, refunded_amount_cents: 4000} = Repo.reload!(ada_payment)
    assert %{status: :refunded, refunded_amount_cents: 2000} = Repo.reload!(ben_payment)

    sent = deliver_emails()
    assert Enum.any?(sent_to(sent, @ada.email), &(&1.subject =~ "Refund Issued - €40.00"))
    assert Enum.any?(sent_to(sent, @ben.email), &(&1.subject =~ "Refund Issued - €20.00"))
  end

  @tag :capture_log
  test "a lapsed hold gives its seats back", %{conn: conn, day: day} do
    %{profile: profile} = organiser("paid-group-lapse", 2)

    {view, time} = open_form(conn, profile, day)
    add_guest(view, "grace@example.com")
    {hold, payment} = pay_at_checkout(view, @ada, "cs_LAPSE", 2)

    # While Ada's checkout is open, her two seats fill the slot.
    {:ok, other, _html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.choose_meeting_type(other, "group-class")
    assert {^day, later} = BookingDriver.pick_first_slot(other, on: day)
    assert later != time

    expired(conn, payment)

    assert %{status: :released} = Repo.reload!(hold)
    assert Repo.get!(MeetingSchema, hold.meeting_id).status == :expired

    {:ok, again, _html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.choose_meeting_type(again, "group-class")
    BookingDriver.pick_date(again, day)

    assert has_element?(
             again,
             "[data-fact='time'][data-value='#{time}'] [data-testid='seat-badge']",
             "2 spots left"
           )
  end

  @tag :capture_log
  test "a payment after the slot filled is refunded", %{conn: conn, day: day} do
    # Two places: the smallest group, and Ada's party takes both.
    %{profile: profile} = organiser("paid-group-late", 2)

    {view, time} = open_form(conn, profile, day)
    add_guest(view, "grace@example.com")
    {ada_hold, ada_payment} = pay_at_checkout(view, @ada, "cs_LATE_ADA", 2)
    expired(conn, ada_payment)
    assert %{status: :released} = Repo.reload!(ada_hold)

    # Ben's party takes the places Ada gave back, and pays.
    {view, ^time} = open_form(build_conn(), profile, day)
    add_guest(view, "hal@example.com")
    {ben_hold, ben_payment} = pay_at_checkout(view, @ben, "cs_LATE_BEN", 2)
    completed(conn, ben_payment)

    # Ada's payment lands after all: the slot is full, so it is refunded.
    completed(conn, ada_payment)

    assert %{status: :paid} = Repo.reload!(ada_payment)

    assert [%{source: :late_payment, amount_cents: 4000}] =
             RefundQueries.list_for_payment(ada_payment.id)

    StripeStub.expect(:create_refund, fn %{form: form} = request ->
      assert form["amount"] == "4000"
      StripeStubResponses.refund(request, "re_" <> form["charge"])
    end)

    assert %{failure: 0} = Oban.drain_queue(queue: :payments, with_scheduled: true)

    assert %{status: :refunded, refunded_amount_cents: 4000} = Repo.reload!(ada_payment)

    assert Enum.any?(
             sent_to(deliver_emails(), @ada.email),
             &(&1.subject =~ "Refund Issued - €40.00")
           )

    session_id = Repo.reload!(ben_hold).meeting_id
    assert [%{email: "ben@example.com"}] = live_participants(session_id)
    refute Repo.get_by(ParticipantSchema, email: @ada.email)
  end

  @tag :capture_log
  test "a participant who cancels keeps no automatic refund and shows as outstanding",
       %{conn: conn, day: day} do
    %{user: host, profile: profile} = organiser("paid-group-leave", 4)

    {view, _time} = open_form(conn, profile, day)
    {_hold, payment} = pay_at_checkout(view, @ada, "cs_LEAVE", 1)
    completed(conn, payment)
    _confirmations = deliver_emails()

    seat = seat_of(@ada.email)

    assert build_conn() |> post(~p"/seat/#{seat.management_token}/cancel") |> html_response(200) =~
             "Spot cancelled"

    assert %{cancelled_at: %DateTime{}} = Repo.reload!(seat)
    assert RefundQueries.list_for_payment(payment.id) == []
    assert %{failure: 0} = Oban.drain_queue(queue: :payments, with_scheduled: true)
    assert %{status: :paid, refunded_amount_cents: 0} = Repo.reload!(payment)

    {:ok, payments, _html} = live(dashboard(host), "/dashboard/integrations?tab=payments")
    assert has_element?(payments, "#outstanding-refund-#{payment.id}")

    assert [cancelled] = sent_to(deliver_emails(), host.email)
    assert cancelled.html_body =~ "Refund outstanding"
  end

  @tag :capture_log
  test "a paid seat moved to another session keeps its payment", %{conn: conn} do
    %{profile: profile} = organiser("paid-group-move", 4)

    # Booked two days out, so the move to tomorrow lands on another session.
    in_two_days = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
    {view, _time} = open_form(conn, profile, in_two_days)
    {hold, payment} = pay_at_checkout(view, @ada, "cs_MOVE", 1)
    completed(conn, payment)

    seat = seat_of(@ada.email)
    token = seat.management_token

    # Moving a seat is not a new sale: no new checkout, no refund.
    StripeStub.stub(:create_checkout_session, fn _request ->
      flunk("a moved seat must not open a checkout")
    end)

    StripeStub.stub(:create_refund, fn _request ->
      flunk("a moved seat must not be refunded")
    end)

    target = build_conn() |> get(~p"/seat/#{token}/reschedule") |> redirected_to()
    {:ok, move, _html} = live(build_conn(), target <> "&timezone=Etc/UTC")

    move = walk_from_schedule_to_booking_form(move, "Etc/UTC")

    assert BookingDriver.submit(move, @ada) =~ "Group Class"

    moved =
      ParticipantSchema
      |> where([p], p.email == ^@ada.email and is_nil(p.cancelled_at))
      |> Repo.one!()

    assert moved.id != seat.id
    assert moved.meeting_id != hold.meeting_id

    assert %{participant_id: participant_id, meeting_id: meeting_id, status: :paid} =
             Repo.reload!(payment)

    assert participant_id == moved.id
    assert meeting_id == moved.meeting_id
    assert RefundQueries.list_for_payment(payment.id) == []
  end

  defp last_segment(path), do: path |> String.split("/") |> List.last()

  # The refunds a host's cancellation of a group session recorded.
  defp cancellation_refunds,
    do: Repo.all(from(r in RefundSchema, where: r.source == :cancellation))
end
