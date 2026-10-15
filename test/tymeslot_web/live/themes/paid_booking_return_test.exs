defmodule TymeslotWeb.Live.Themes.PaidBookingReturnTest do
  @moduledoc """
  A paid booking walked from each theme's organiser page to Stripe and back.

  The visitor books a paid meeting type on the top-level booking page, which
  sends them to Stripe Checkout. Stripe returns them to the success or the
  cancel URL the checkout session was created with; this suite follows those
  URLs as the session carries them, so the theme slug in the path is the one
  the booking flow chose, not one written into the test. The success URL
  must land on the theme's own processing page, which turns into the
  confirmation once the `checkout.session.completed` webhook is handled; the
  cancel URL must land on the theme's own cancelled page, offering the way
  back to the meeting type. The setup is `embed_paid_booking_test.exs`'s.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :payments
  @moduletag :themes
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

  @session_id "cs_RETURN"
  @checkout_url "https://checkout.stripe.com/c/pay/cs_RETURN"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # Core ships with meeting payments off; without this the paid branch
    # never reaches the Stripe adapter.
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

  test "the matrix is not empty" do
    assert ThemeTestMatrix.registered() != []
  end

  for theme <- ThemeTestMatrix.registered() do
    describe "#{theme.slug}" do
      setup do
        %{user: user, profile: profile} =
          seed_organiser(unquote(theme.id), "paid-#{unquote(theme.slug)}",
            types: [
              [
                name: "Paid Consult",
                duration_minutes: 30,
                payment_required: true,
                price_cents: 5000
              ]
            ]
          )

        insert(:connect_account,
          user: user,
          stripe_account_id: "acct_RETURN",
          default_currency: "usd",
          charges_enabled: true
        )

        %{profile: profile}
      end

      @tag :capture_log
      test "the success URL lands on the theme's processing page and its confirmation",
           %{conn: conn, profile: profile} do
        %{success_url: success_url} = book_to_checkout(conn, profile)
        slug = unquote(theme.slug)

        %{"meeting_id" => meeting_id} =
          Regex.named_captures(
            ~r{^/themes/#{slug}/payment-processing/(?<meeting_id>[^/?]+)\?session_id=#{@session_id}$},
            success_url
          ) || flunk("expected a #{slug} processing URL, got #{success_url}")

        assert Repo.get!(MeetingSchema, meeting_id).status == "awaiting_payment"

        {:ok, view, _html} = live(conn, success_url)
        shell = "[data-testid='#{slug}-payment-processing']"
        assert has_element?(view, "#{shell} h1", "Confirming your payment")

        assert :ok =
                 CheckoutSessionCompleted.handle(%{
                   "id" => "evt_RETURN",
                   "type" => "checkout.session.completed",
                   "created" => System.os_time(:second),
                   "data" => %{
                     "object" => %{
                       "id" => @session_id,
                       "client_reference_id" => meeting_id,
                       "payment_status" => "paid"
                     }
                   }
                 })

        assert has_element?(view, "#{shell} h1", "Booking confirmed")
        assert Repo.get!(MeetingSchema, meeting_id).status == "confirmed"
      end

      @tag :capture_log
      test "the cancel URL lands on the theme's cancelled page with the way back",
           %{conn: conn, profile: profile} do
        %{cancel_url: cancel_url} = book_to_checkout(conn, profile)
        slug = unquote(theme.slug)

        assert cancel_url =~ ~r{^/themes/#{slug}/payment-cancelled/[^/?]+$}

        {:ok, view, _html} = live(conn, cancel_url)
        shell = "[data-testid='#{slug}-payment-cancelled']"

        assert has_element?(view, "#{shell} h1", "Payment cancelled")

        assert has_element?(
                 view,
                 "#{shell} a[href='/#{profile.username}/paid-consult']",
                 "Return to booking"
               )
      end
    end
  end

  # Books the paid meeting type on the organiser's page through the markup
  # contract, asserts the visitor is sent to Stripe Checkout, and returns
  # the return URLs the checkout session was created with, as paths.
  defp book_to_checkout(conn, profile) do
    test_pid = self()

    expect(StripeAdapterMock, :create_checkout_session, fn params, opts ->
      assert opts[:connect_account] == "acct_RETURN"
      send(test_pid, {:checkout_session, params})
      {:ok, %{id: @session_id, url: @checkout_url}}
    end)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")

    BookingDriver.book(view, meeting_type: "paid-consult", until: :attendee)

    # Submitted here rather than by `BookingDriver.submit/2`, which waits on
    # the LiveView afterwards: a paid booking leaves the page for Stripe. The
    # submission is handled through a message to the LiveView, so the
    # redirect arrives after `render_submit/1` returns.
    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay Pat", "email" => "pat@example.com", "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    assert_received {:checkout_session, params}

    %{
      success_url:
        params.success_url
        |> String.replace("{CHECKOUT_SESSION_ID}", @session_id)
        |> path_of(),
      cancel_url: path_of(params.cancel_url)
    }
  end

  defp path_of(url) do
    base = Endpoint.url()
    assert String.starts_with?(url, base), "expected #{url} to start with #{base}"
    String.replace_prefix(url, base, "")
  end
end
