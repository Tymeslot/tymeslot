defmodule TymeslotWeb.Live.Themes.MultipleLengthsPaidBookingTest do
  @moduledoc """
  A paid meeting type offering several lengths, booked at one that is not its
  own: the booker chooses an hour on a 30-minute type, is sent to Stripe
  Checkout, waits on the theme's processing page and lands on its
  confirmation once the `checkout.session.completed` webhook is handled.

  The hour must hold the whole way through: the held booking, the checkout
  and the confirmed meeting all carry the length chosen, while the price
  charged stays the type's own, since a length does not change it. The setup
  is `paid_booking_return_test.exs`'s.
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
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.ThemeTestMatrix

  @session_id "cs_LENGTHS"
  @checkout_url "https://checkout.stripe.com/c/pay/cs_LENGTHS"
  @price_cents 5000

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

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.slug}" do
      @tag :capture_log
      test "a paid booking at a length not the type's own keeps it through checkout and confirmation",
           %{conn: conn} do
        slug = unquote(theme.slug)

        %{user: user, profile: profile} =
          seed_organiser(unquote(theme.id), "paid-lengths-#{slug}",
            types: [
              [
                name: "Paid Consult",
                duration_minutes: 30,
                extra_lengths_minutes: [60],
                payment_required: true,
                price_cents: @price_cents
              ]
            ]
          )

        insert(:connect_account,
          user: user,
          stripe_account_id: "acct_LENGTHS",
          default_currency: "usd",
          charges_enabled: true
        )

        %{params: params, success_url: success_url} = book_to_checkout(conn, profile)

        # The price is the type's whatever the length.
        assert [%{price_data: %{unit_amount: @price_cents}, quantity: 1}] = params.line_items

        # Held for the hour while the visitor pays.
        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.status == :awaiting_payment
        assert_hour(meeting)

        {:ok, view, _html} = live(conn, success_url)
        shell = "[data-testid='#{slug}-payment-processing']"
        assert has_element?(view, "#{shell} h1", "Confirming your payment")

        assert :ok =
                 CheckoutSessionCompleted.handle(%{
                   "id" => "evt_LENGTHS",
                   "type" => "checkout.session.completed",
                   "account" => "acct_LENGTHS",
                   "created" => System.os_time(:second),
                   "data" => %{
                     "object" => %{
                       "id" => @session_id,
                       "client_reference_id" => meeting.id,
                       "payment_status" => "paid",
                       "amount_total" => @price_cents,
                       "currency" => "usd"
                     }
                   }
                 })

        assert has_element?(view, "#{shell} h1", "Booking confirmed")

        confirmed = Repo.reload!(meeting)
        assert confirmed.status == :confirmed
        assert_hour(confirmed)
        assert confirmed.end_time == meeting.end_time
      end
    end
  end

  defp assert_hour(meeting) do
    assert meeting.duration == 60
    assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 60
  end

  # Books the paid type at an hour through the markup contract, asserts the
  # visitor is sent to Stripe Checkout, and returns the session's params and
  # its success URL as a path.
  defp book_to_checkout(conn, profile) do
    test_pid = self()

    expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
      assert opts[:connect_account] == "acct_LENGTHS"
      send(test_pid, {:checkout_session, params})
      {:ok, %{id: @session_id, url: @checkout_url}}
    end)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")

    BookingDriver.book(view, meeting_type: "paid-consult", length: 60, until: :attendee)

    # Submitted here rather than by `BookingDriver.submit/2`, which waits on
    # the LiveView afterwards: a paid booking leaves the page for Stripe.
    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay Pat", "email" => "pat@example.com", "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    assert_received {:checkout_session, params}

    success_url =
      params.success_url
      |> String.replace("{CHECKOUT_SESSION_ID}", @session_id)
      |> String.replace_prefix(Endpoint.url(), "")

    %{params: params, success_url: success_url}
  end
end
