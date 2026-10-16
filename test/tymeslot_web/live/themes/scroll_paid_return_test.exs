defmodule TymeslotWeb.Live.Themes.ScrollPaidReturnTest do
  @moduledoc """
  A paid booking on Fixture Scroll (`"96"`), a `Continuous` journey, from
  inside an embed: Stripe Checkout opens in a new tab and the page waits in
  the shared awaiting-payment outcome. A lapsed payment brings the visitor
  back to the attendee moment with every choice still made, on the same page
  as the moments before it; a paid one shows the confirmation. The setup is
  `embed_paid_booking_test.exs`'s.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :bookings
  @moduletag :payments
  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers

  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @theme_id "96"

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

    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    %{user: user, profile: profile} =
      seed_organiser(@theme_id, "scroll-paid",
        profile: [allowed_embed_domains: ["embedder.test"]],
        types: [
          [name: "Paid Consult", duration_minutes: 30, payment_required: true, price_cents: 5000]
        ]
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_SCROLL",
      default_currency: "usd",
      charges_enabled: true
    )

    %{profile: profile}
  end

  defp state(view, moment), do: first_value(view, "##{moment}-step", "data-moment-state")

  # Books in an embed up to the awaiting-payment outcome; returns the view
  # and the meeting's id.
  defp book_and_await_payment(conn, profile) do
    expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
      {:ok, %{id: "cs_scroll", url: "https://checkout.stripe.com/cs_scroll"}}
    end)

    conn = put_req_header(conn, "referer", "https://embedder.test/page")
    {:ok, view, _html} = live(conn, "/#{profile.username}?embed=1&timezone=UTC")

    assert live_assigns(view)[:embedded] == true

    BookingDriver.choose_meeting_type(view, "paid-consult")
    BookingDriver.pick_time(view, await_first_time(view))
    BookingDriver.submit(view, %{name: "Pay Pat", email: "pat@example.com"})
    _drain = :sys.get_state(view.pid)

    assert has_element?(view, "[data-testid='awaiting-payment']")
    refute has_element?(view, "#you-step")

    {view, live_assigns(view)[:awaiting_payment_meeting].id}
  end

  @tag :capture_log
  test "a lapsed payment returns to the attendee moment with every choice kept", %{
    conn: conn,
    profile: profile
  } do
    {view, meeting_id} = book_and_await_payment(conn, profile)
    chosen = Map.take(live_assigns(view), [:selected_date, :selected_time])

    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :expired)
    _drain = :sys.get_state(view.pid)

    assert render(view) =~ "Payment was cancelled"
    assert state(view, :offer) == "done"
    assert state(view, :when) == "done"
    assert state(view, :you) == "current"
    assert Map.take(live_assigns(view), [:selected_date, :selected_time]) == chosen
    assert has_element?(view, "[data-testid='summary-bar-meeting-type']", "Paid Consult")
    assert has_element?(view, "[data-testid='summary-bar-slot']")
    returned = live_assigns(view).submission_token
    assert byte_size(returned) > 0

    # The page carries on from the attendee moment: another day forgets the
    # time, and a time on it opens the details again, entered afresh.
    BookingDriver.pick_date(view, another_free_date(view, chosen.selected_date))
    BookingDriver.pick_time(view, await_first_time(view))

    assert state(view, :you) == "current"
    renewed = live_assigns(view).submission_token
    assert byte_size(renewed) > 0
    assert renewed != returned
  end

  @tag :capture_log
  test "a paid booking shows the confirmation", %{conn: conn, profile: profile} do
    {view, meeting_id} = book_and_await_payment(conn, profile)

    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting_id}", :paid)
    _drain = :sys.get_state(view.pid)

    assert has_element?(view, "[data-testid='confirmation-heading']")
    refute has_element?(view, "#you-step")
    refute has_element?(view, "[data-testid='awaiting-payment']")
  end

  # A repeated broadcast for the booking just paid must not move the next one.
  @tag :capture_log
  test "Book another forgets the paid meeting's payment", %{conn: conn, profile: profile} do
    {view, meeting_id} = book_and_await_payment(conn, profile)
    topic = "meeting_payment:#{meeting_id}"

    Phoenix.PubSub.broadcast(Tymeslot.PubSub, topic, :paid)
    _drain = :sys.get_state(view.pid)
    assert has_element?(view, "[data-testid='confirmation-heading']")

    BookingDriver.restart(view)

    assert live_assigns(view).awaiting_payment_meeting == nil
    refute view.pid in Enum.map(Registry.lookup(Tymeslot.PubSub, topic), &elem(&1, 0))

    Phoenix.PubSub.broadcast(Tymeslot.PubSub, topic, :paid)
    _drain = :sys.get_state(view.pid)

    refute has_element?(view, "[data-testid='confirmation-heading']")
    assert state(view, :offer) in ["current", "done"]
  end
end
