defmodule TymeslotWeb.Live.Scheduling.PaidGroupBookingTest do
  @moduledoc """
  Booking a seat on a paid group meeting type, from the booking page to the
  payment's outcome.

  A group type charges each seat: the booker's and one for each guest they
  add. The submit says what the checkout will charge for all of them, on
  every shipped theme. Submitting holds the seats (`Tymeslot.Meetings.SeatHolds`)
  and opens Stripe Checkout: at the top level the page goes there, inside an
  embed it opens a new tab and waits on the hold's own topic, reaching the
  seat's confirmation when the payment webhook converts the hold, or the
  booking form again when the hold lapses.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :payments
  @moduletag :scheduling
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeWebhookFixtures
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  @account "acct_GROUP"
  @submit_price "[data-testid='submit-price']"
  @checkout_url "https://checkout.stripe.com/c/pay/cs_GROUP"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 50
    )

    old_recaptcha = Application.get_env(:tymeslot, :recaptcha, [])

    Application.put_env(
      :tymeslot,
      :recaptcha,
      Keyword.put(old_recaptcha, :booking_enabled, false)
    )

    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_recaptcha) end)

    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    # The completion webhook looks up the charge; these payments have none.
    stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
      {:ok, %{"latest_charge" => nil}}
    end)

    :ok
  end

  test "the matrix is not empty" do
    assert ThemeTestMatrix.all() != []
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}" do
      setup do
        %{profile: seed_group_organiser(unquote(theme.id), "group-#{unquote(theme.slug)}")}
      end

      test "the submit shows the total for the booker and their guests",
           %{conn: conn, profile: profile} do
        view = open_form(conn, "/#{profile.username}?timezone=UTC")

        assert has_element?(view, @submit_price, "€20.00 per person")

        add_guest(view, "first@example.com")
        add_guest(view, "second@example.com")
        assert has_element?(view, @submit_price, "€60.00 for 3 seats")

        remove_guest(view, "second@example.com")
        assert has_element?(view, @submit_price, "€40.00 for 2 seats")
      end
    end
  end

  describe "at the top level" do
    setup do
      %{profile: seed_group_organiser("1", "group-top")}
    end

    @tag :capture_log
    test "booking a paid seat redirects to Stripe Checkout", %{conn: conn, profile: profile} do
      expect_checkout("cs_GROUP")
      view = open_form(conn, "/#{profile.username}?timezone=UTC")
      add_guest(view, "friend@example.com")

      submit(view)

      assert_redirect(view, @checkout_url, 5_000)

      assert [%SeatHoldSchema{status: :held, seats: 2, email: "pat@example.com"}] =
               Repo.all(SeatHoldSchema)

      assert Repo.all(ParticipantSchema) == []
    end
  end

  describe "inside an embed" do
    setup do
      %{profile: seed_group_organiser("1", "group-embed")}
    end

    @tag :capture_log
    test "an embedded paid seat confirms in the iframe when payment lands",
         %{conn: conn, profile: profile} do
      view = submit_embedded(conn, profile, "cs_GROUP_PAID")
      hold = :sys.get_state(view.pid).socket.assigns.awaiting_payment_hold
      assert %SeatHoldSchema{seats: 2} = hold

      payment = Repo.get_by!(BookingPaymentSchema, seat_hold_id: hold.id)
      assert :ok = CheckoutSessionCompleted.handle(completed_event(payment))
      _drain = :sys.get_state(view.pid)

      %SeatHoldSchema{status: :converted, participant_id: participant_id} =
        SeatHolds.get(hold.id)

      {:ok, seat} = SeatView.for_participant(participant_id)
      {:seat, calendar_url} = Meetings.booker_calendar(seat)

      assert has_element?(view, "[data-testid='confirmation-heading']")
      assert has_element?(view, "a[href='#{calendar_url}']")
      assert has_element?(view, "[data-testid='confirmation-paid']", "€40.00")
      refute has_element?(view, "[data-testid='awaiting-payment']")
      assert :sys.get_state(view.pid).socket.assigns.awaiting_payment_hold == nil
    end

    @tag :capture_log
    test "an embedded paid seat returns to the booking form when the hold expires",
         %{conn: conn, profile: profile} do
      view = submit_embedded(conn, profile, "cs_GROUP_LAPSE")
      hold = :sys.get_state(view.pid).socket.assigns.awaiting_payment_hold
      topic = SeatHolds.topic(hold.id)

      payment = Repo.get_by!(BookingPaymentSchema, seat_hold_id: hold.id)
      assert :ok = CheckoutSessionExpired.handle(expired_event(payment))
      _drain = :sys.get_state(view.pid)

      assert render(view) =~ "Payment was cancelled"
      refute has_element?(view, "[data-testid='awaiting-payment']")
      assert has_element?(view, "form[data-fact='attendee']")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.awaiting_payment_hold == nil
      assert assigns.awaiting_payment_meeting == nil
      refute view.pid in Enum.map(Registry.lookup(Tymeslot.PubSub, topic), &elem(&1, 0))
    end

    # A seat's wait ends only on its hold's own message: a bare `:paid`
    # names no seat, and the group meeting has no attendee to confirm.
    @tag :capture_log
    test "a bare :paid does not end a seat's wait", %{conn: conn, profile: profile} do
      view = submit_embedded(conn, profile, "cs_GROUP_BARE")

      send(view.pid, :paid)
      _drain = :sys.get_state(view.pid)

      assert has_element?(view, "[data-testid='awaiting-payment']")
      refute has_element?(view, "[data-testid='confirmation-heading']")
    end
  end

  # An organiser on `theme_id` with one paid group type, "Group Class": five
  # places at €20.00 each, guests allowed, and a Stripe account in euros.
  defp seed_group_organiser(theme_id, username) do
    %{user: user, profile: profile} =
      seed_organiser(theme_id, username,
        profile: [allowed_embed_domains: ["embedder.test"]],
        types: [
          [
            name: "Group Class",
            duration_minutes: 30,
            max_participants: 5,
            allow_guests: true,
            payment_required: true,
            price_cents: 2000
          ]
        ]
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: @account,
      default_currency: "eur",
      charges_enabled: true
    )

    profile
  end

  defp open_form(conn, path) do
    {:ok, view, _html} = live(conn, path)
    BookingDriver.book(view, meeting_type: "group-class", until: :attendee)
    view
  end

  defp add_guest(view, email) do
    unless has_element?(view, "#guest-add-form") do
      view |> element("[data-testid='guest-toggle']") |> render_click()
    end

    view |> form("#guest-add-form", %{"guest_email" => email}) |> render_submit()
  end

  defp remove_guest(view, email) do
    view
    |> element("button[phx-click='remove_guest'][phx-value-email='#{email}']")
    |> render_click()
  end

  # Submitted here rather than by `BookingDriver.submit/2`, which waits on
  # the page afterwards: a paid booking leaves it for Stripe.
  defp submit(view) do
    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay Pat", "email" => "pat@example.com", "message" => ""}
    })
    |> render_submit()
  end

  defp expect_checkout(session_id) do
    expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
      assert opts[:connect_account] == @account
      assert [%{quantity: _seats}] = params.line_items

      {:ok,
       %{
         id: session_id,
         url: "https://checkout.stripe.com/c/pay/#{session_id}",
         payment_intent: nil
       }}
    end)
  end

  # Books a seat and one guest inside the embed, and returns the view once
  # it waits on the payment, having pushed the checkout to a new tab.
  defp submit_embedded(conn, profile, session_id) do
    expect_checkout(session_id)
    url = "https://checkout.stripe.com/c/pay/#{session_id}"

    conn = put_req_header(conn, "referer", "https://embedder.test/page")
    view = open_form(conn, "/#{profile.username}?embed=1&timezone=UTC")
    assert :sys.get_state(view.pid).socket.assigns[:embedded] == true
    add_guest(view, "friend@example.com")

    submit(view)
    _drain = :sys.get_state(view.pid)

    assert_push_event(view, "payment_redirect_open_tab", %{url: ^url})
    assert has_element?(view, "[data-testid='awaiting-payment']")
    view
  end

  defp completed_event(payment) do
    session_event(payment, "checkout.session.completed", %{
      "payment_intent" => "pi_#{payment.seat_hold_id}",
      "payment_status" => "paid",
      "amount_total" => payment.amount_cents,
      "currency" => payment.currency
    })
  end

  defp expired_event(payment) do
    session_event(payment, "checkout.session.expired", %{
      "payment_status" => "unpaid",
      "status" => "expired"
    })
  end

  defp session_event(payment, type, object) do
    "checkout.session.completed"
    |> StripeWebhookFixtures.event()
    |> Map.merge(%{"id" => "evt_#{payment.id}_#{type}", "type" => type, "account" => @account})
    |> update_in(["data", "object"], fn session ->
      Map.merge(
        session,
        Map.merge(
          %{
            "id" => payment.stripe_checkout_session_id,
            "client_reference_id" => "seat_hold:" <> payment.seat_hold_id,
            "metadata" => %{"seat_hold_id" => payment.seat_hold_id}
          },
          object
        )
      )
    end)
  end
end
