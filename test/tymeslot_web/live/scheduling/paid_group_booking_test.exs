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

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
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
    StripeStub.stub(
      :retrieve_payment_intent,
      StripeFixtures.object("payment_intent_with_latest_charge", %{"latest_charge" => nil})
    )

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

        # The submit is described by the element that holds the total.
        assert has_element?(view, "#submit-price-amount", "€60.00 for 3 seats")

        assert has_element?(
                 view,
                 "[data-intent='submit'][aria-describedby~='submit-price-amount']"
               )

        remove_guest(view, "second@example.com")
        assert has_element?(view, @submit_price, "€40.00 for 2 seats")
      end

      # The booking drops a guest who is the booker, so the submit does too.
      test "a guest who is the booker takes no seat of their own",
           %{conn: conn, profile: profile} do
        view = open_form(conn, "/#{profile.username}?timezone=UTC")

        add_guest(view, "pat@example.com")
        assert has_element?(view, @submit_price, "€40.00 for 2 seats")

        fill_booker(view, "pat@example.com")
        assert has_element?(view, @submit_price, "€20.00 per person")
        refute has_element?(view, @submit_price, "seats")
      end
    end
  end

  describe "at the top level" do
    setup do
      %{profile: seed_group_organiser("1", "group-top")}
    end

    # The checkout charges the seats the submit showed: one, not two.
    @tag :capture_log
    test "a guest who is the booker is not charged a seat", %{conn: conn, profile: profile} do
      expect_checkout("cs_GROUP_SELF")
      view = open_form(conn, "/#{profile.username}?timezone=UTC")
      add_guest(view, "pat@example.com")
      fill_booker(view, "pat@example.com")
      assert has_element?(view, @submit_price, "€20.00 per person")

      submit(view)

      assert_redirect(view, "https://checkout.stripe.com/c/pay/cs_GROUP_SELF", 5_000)
      assert [%SeatHoldSchema{seats: 1} = hold] = Repo.all(SeatHoldSchema)

      assert %{seats: 1, amount_cents: 2000} =
               Repo.get_by!(BookingPaymentSchema, seat_hold_id: hold.id)
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

    # Leaving Stripe by the browser's back button leaves the checkout, and
    # its hold, open: the same booking again is told to finish that payment,
    # never that the booker has a seat.
    @tag :capture_log
    test "a booker back from an unfinished checkout is told it is still open",
         %{conn: conn, profile: profile} do
      expect_checkout("cs_GROUP_OPEN")
      first = open_form(conn, "/#{profile.username}?timezone=UTC")
      submit(first)
      assert_redirect(first, "https://checkout.stripe.com/c/pay/cs_GROUP_OPEN", 5_000)

      again = open_form(conn, "/#{profile.username}?timezone=UTC")
      submit(again)
      _drain = render_async(again, 5_000)

      html = render(again)
      assert html =~ "A payment for this email is still open for this time."
      refute html =~ "You already have a spot"
      assert [%SeatHoldSchema{status: :held}] = Repo.all(SeatHoldSchema)
    end
  end

  describe "inside an embed" do
    setup do
      profile = seed_group_organiser("1", "group-embed")

      # One venue, so the confirmation has a location to show.
      venue = insert(:venue, user: Repo.preload(profile, :user).user, name: "Main Hall")

      MeetingTypeSchema
      |> Repo.get_by!(user_id: profile.user_id)
      |> Changeset.change()
      |> Changeset.put_embed(:locations, [in_person_location([venue])])
      |> Repo.update!()

      %{profile: profile}
    end

    @tag :capture_log
    test "an embedded paid seat confirms in the iframe when payment lands",
         %{conn: conn, profile: profile} do
      {view, hold} = submit_embedded(conn, profile, "cs_GROUP_PAID")
      assert %SeatHoldSchema{seats: 2, name: "Pay Pat", email: "pat@example.com"} = hold
      topic = SeatHolds.topic(hold.id)
      assert subscribed?(view, topic)

      payment = Repo.get_by!(BookingPaymentSchema, seat_hold_id: hold.id)
      assert :ok = CheckoutSessionCompleted.handle(completed_event(payment))
      _drain = render(view)

      %SeatHoldSchema{status: :converted, participant_id: participant_id} =
        SeatHolds.get(hold.id)

      {:ok, seat} = SeatView.for_participant(participant_id)
      {:seat, calendar_url} = Meetings.booker_calendar(seat)

      assert has_element?(view, "[data-testid='confirmation-heading']")
      assert has_element?(view, "a[href='#{calendar_url}']")
      assert has_element?(view, "[data-testid='confirmation-paid']", "€40.00")
      assert has_element?(view, "[data-testid='confirmation-location']", "Main Hall")
      assert render(view) =~ "Pay Pat"
      assert render(view) =~ "pat@example.com"
      refute has_element?(view, "[data-testid='awaiting-payment']")
      refute subscribed?(view, topic)
    end

    # A repeated broadcast (PubSub redelivery, a second webhook) finds the
    # wait already over and changes nothing.
    @tag :capture_log
    test "a second {:paid, _} for the seat is ignored", %{conn: conn, profile: profile} do
      {view, hold} = submit_embedded(conn, profile, "cs_GROUP_TWICE")
      payment = Repo.get_by!(BookingPaymentSchema, seat_hold_id: hold.id)
      assert :ok = CheckoutSessionCompleted.handle(completed_event(payment))
      _drain = render(view)
      confirmed = view |> element("[data-testid='confirmation-heading']") |> render()

      %SeatHoldSchema{participant_id: participant_id} = SeatHolds.get(hold.id)
      send(view.pid, {:paid, participant_id})

      assert Process.alive?(view.pid)
      assert view |> element("[data-testid='confirmation-heading']") |> render() == confirmed
    end

    # The payment went through, so the booker is not left waiting: the
    # confirmation shows, without the seat's calendar file it cannot read.
    test "a {:paid, _} naming no participant still confirms, with a warning",
         %{conn: conn, profile: profile} do
      {view, _hold} = submit_embedded(conn, profile, "cs_GROUP_GONE")

      log =
        capture_log([level: :warning], fn ->
          send(view.pid, {:paid, UUID.generate()})
          _drain = render(view)
        end)

      assert log =~ "Paid seat not found for its confirmation"
      assert has_element?(view, "[data-testid='confirmation-heading']")
      refute has_element?(view, "[data-testid='awaiting-payment']")
      refute has_element?(view, "a[href$='.ics']")
      refute has_element?(view, "[data-testid='confirmation-paid']")
    end

    @tag :capture_log
    test "an embedded paid seat returns to the booking form when the hold expires",
         %{conn: conn, profile: profile} do
      {view, hold} = submit_embedded(conn, profile, "cs_GROUP_LAPSE")
      topic = SeatHolds.topic(hold.id)

      payment = Repo.get_by!(BookingPaymentSchema, seat_hold_id: hold.id)
      assert :ok = CheckoutSessionExpired.handle(expired_event(payment))
      _drain = render(view)

      assert render(view) =~ "Payment was cancelled"
      refute has_element?(view, "[data-testid='awaiting-payment']")
      assert has_element?(view, "form[data-fact='attendee']")
      refute subscribed?(view, topic)
      refute subscribed?(view, Checkout.payment_topic(hold.meeting_id))
    end

    # A seat's wait ends only on its hold's own message: a bare `:paid`
    # names no seat, and the group meeting has no attendee to confirm.
    @tag :capture_log
    test "a bare :paid does not end a seat's wait", %{conn: conn, profile: profile} do
      {view, hold} = submit_embedded(conn, profile, "cs_GROUP_BARE")

      send(view.pid, :paid)
      _drain = render(view)

      assert has_element?(view, "[data-testid='awaiting-payment']")
      refute has_element?(view, "[data-testid='confirmation-heading']")
      assert subscribed?(view, SeatHolds.topic(hold.id))
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

  defp fill_booker(view, email) do
    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay Pat", "email" => email, "message" => ""}
    })
    |> render_change()
  end

  defp subscribed?(view, topic),
    do: view.pid in Enum.map(Registry.lookup(Tymeslot.PubSub, topic), &elem(&1, 0))

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
    StripeStub.expect(:create_checkout_session, fn %{form: form, headers: headers} ->
      assert headers["stripe-account"] == @account
      assert [%{"quantity" => _seats}] = form["line_items"]

      StripeFixtures.object("checkout_session_payment", %{
        "id" => session_id,
        "url" => "https://checkout.stripe.com/c/pay/#{session_id}"
      })
    end)
  end

  # Books a seat and one guest inside the embed, and returns the view and
  # the hold once it waits on the payment, having pushed the checkout to a
  # new tab (which only an embedded page does).
  defp submit_embedded(conn, profile, session_id) do
    expect_checkout(session_id)
    url = "https://checkout.stripe.com/c/pay/#{session_id}"

    conn = put_req_header(conn, "referer", "https://embedder.test/page")
    view = open_form(conn, "/#{profile.username}?embed=1&timezone=UTC")
    add_guest(view, "friend@example.com")

    submit(view)
    _drain = render(view)

    assert_push_event(view, "payment_redirect_open_tab", %{url: ^url})
    assert has_element?(view, "[data-testid='awaiting-payment']")
    {view, Repo.get_by!(SeatHoldSchema, email: "pat@example.com")}
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
