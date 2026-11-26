defmodule TymeslotWeb.Live.Themes.PaidBookingReturnTest do
  @moduledoc """
  A paid booking walked from each theme's organiser page to Stripe and back.

  The visitor books a paid meeting type on the top-level booking page, which
  sends them to Stripe Checkout. Stripe returns them to the success or the
  cancel URL the checkout session was created with; this suite follows those
  URLs as the session carries them, so the theme slug in the path is the one
  the booking flow chose, not one written into the test. The success URL
  must land on the theme's own processing page, which turns into the
  confirmation, saying what was paid, once the `checkout.session.completed`
  webhook is handled; the
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
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.TestMocks
  alias Tymeslot.Themes.Catalog
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

    # Landing on the cancelled page ends the checkout at Stripe.
    StripeStub.stub(
      :expire_checkout_session,
      StripeFixtures.object("checkout_session_expired", %{"id" => @session_id})
    )

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

    # The completion webhook looks up the charge; these payments have none.
    StripeStub.stub(
      :retrieve_payment_intent,
      StripeFixtures.object("payment_intent_with_latest_charge", %{"latest_charge" => nil})
    )

    :ok
  end

  test "the matrix is not empty" do
    assert ThemeTestMatrix.registered() != []
  end

  for theme <- ThemeTestMatrix.registered() do
    describe "#{theme.slug}" do
      setup do
        %{profile: seed_paid_organiser(unquote(theme.id), "paid-#{unquote(theme.slug)}")}
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

        assert Repo.get!(MeetingSchema, meeting_id).status == :awaiting_payment

        {:ok, view, _html} = live(conn, success_url)
        shell = "[data-testid='#{slug}-payment-processing']"
        assert has_element?(view, "#{shell} h1", "Confirming your payment")
        refute has_element?(view, "#{shell} [data-testid='payment-paid-amount']")

        assert :ok =
                 CheckoutSessionCompleted.handle(%{
                   "id" => "evt_RETURN",
                   "type" => "checkout.session.completed",
                   "account" => "acct_RETURN",
                   "created" => System.os_time(:second),
                   "data" => %{
                     "object" => %{
                       "id" => @session_id,
                       "client_reference_id" => meeting_id,
                       "payment_status" => "paid",
                       "amount_total" => 5000,
                       "currency" => "usd"
                     }
                   }
                 })

        assert has_element?(view, "#{shell} h1", "Booking confirmed")
        assert has_element?(view, "#{shell} [data-testid='payment-paid-amount']", "Paid: $50.00")
        assert Repo.get!(MeetingSchema, meeting_id).status == :confirmed
      end

      @tag :capture_log
      test "the cancel URL lands on the theme's cancelled page with the way back",
           %{conn: conn, profile: profile} do
        %{cancel_url: cancel_url} = book_to_checkout(conn, profile)
        slug = unquote(theme.slug)

        assert cancel_url =~ ~r{^/themes/#{slug}/payment-cancelled/[^/?]+\?return_token=[^&]+$}

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

  describe "the organiser on the return pages" do
    @tag :capture_log
    test "Folio draws the organiser's portrait and name above both pages", %{conn: conn} do
      {:ok, folio} = Catalog.key_to_id(:folio)
      profile = seed_paid_organiser(folio, "paid-folio-organiser", full_name: "Mia Laurent")
      %{success_url: success_url, cancel_url: cancel_url} = book_to_checkout(conn, profile)
      avatar = Profiles.avatar_url(profile, :original)

      for url <- [success_url, cancel_url] do
        {:ok, view, _html} = live(conn, url)

        assert has_element?(view, ".folio-plain-page .folio-masthead img.folio-portrait")
        assert has_element?(view, ".folio-masthead img.folio-portrait[src='#{avatar}']")
        assert has_element?(view, ".folio-masthead .folio-identity__name", "Mia Laurent")
      end
    end

    # Paper's shell is handed the profile too, and must draw nothing of it.
    @tag :capture_log
    test "Paper's pages stay without the organiser's portrait or name", %{conn: conn} do
      {:ok, paper} = Catalog.key_to_id(:paper)
      profile = seed_paid_organiser(paper, "paid-paper-organiser", full_name: "Mia Laurent")
      %{success_url: success_url, cancel_url: cancel_url} = book_to_checkout(conn, profile)
      avatar = Profiles.avatar_url(profile, :original)

      for {url, page} <- [{success_url, "payment-processing"}, {cancel_url, "payment-cancelled"}] do
        {:ok, view, _html} = live(conn, url)

        assert has_element?(view, "[data-testid='paper-#{page}']")
        refute has_element?(view, "img[src='#{avatar}']")
        refute render(view) =~ "Mia Laurent"
      end
    end
  end

  # A group seat's checkout returns to pages keyed by its hold, never by the
  # shared meeting, whose status is the session's, not the booker's.
  describe "a paid group seat" do
    setup do
      %{user: user, profile: profile} =
        seed_organiser("1", "paid-seat",
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
        stripe_account_id: "acct_RETURN",
        default_currency: "eur",
        charges_enabled: true
      )

      %{user: user, profile: profile}
    end

    @tag :capture_log
    test "the seat return page waits, then confirms", %{conn: conn, profile: profile} do
      %{success_url: success_url, hold_id: hold_id} = book_seat_to_checkout(conn, profile)

      {:ok, view, _html} = live(conn, success_url)
      shell = "[data-testid='quill-payment-processing']"
      assert has_element?(view, "#{shell} h1", "Confirming your payment")

      payment = BookingPayments.payment_for_seat_hold(hold_id)
      assert :ok = CheckoutSessionCompleted.handle(seat_completed_event(payment))

      assert has_element?(view, "#{shell} h1", "Booking confirmed")
      assert has_element?(view, "#{shell} [data-testid='payment-paid-amount']", "Paid: €40.00")
      assert %{status: :converted} = SeatHolds.get(hold_id)
    end

    @tag :capture_log
    test "the seat return page refuses a wrong session id", %{conn: conn, profile: profile} do
      %{hold_id: hold_id} = book_seat_to_checkout(conn, profile)

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/themes/quill/payment-processing/seat/#{hold_id}?session_id=cs_OTHER")

      assert {:error, {:redirect, %{to: "/"}}} =
               live(conn, "/themes/quill/payment-processing/seat/not-a-hold?session_id=cs_OTHER")
    end

    test "the seat return page reports a lapsed hold as expired although the meeting is confirmed",
         %{conn: conn, user: user} do
      view =
        seat_return_page(conn, user, %{status: :released, released_reason: :expired, seats: 2}, %{
          status: :failed
        })

      shell = "[data-testid='quill-payment-processing']"
      assert has_element?(view, "#{shell} h1", "Your seats were released")
      assert has_element?(view, "#{shell} p", "so the seats held for you were released")
      refute has_element?(view, "#{shell} h1", "Booking confirmed")
      assert has_element?(view, "#{shell} a[href='/paid-seat/group-class']", "Return to booking")
    end

    test "a single lapsed seat reads in the singular", %{conn: conn, user: user} do
      view = seat_return_page(conn, user, %{status: :released, released_reason: :expired})

      assert has_element?(
               view,
               "[role='status'][aria-live='polite'] h1",
               "Your seat was released"
             )

      assert has_element?(view, "p", "so the seat held for you was released")
    end

    test "a payment that came after the hold lapsed is refunded",
         %{conn: conn, user: user} do
      view =
        seat_return_page(conn, user, %{status: :released, released_reason: :expired}, %{
          status: :refunded,
          paid_at: DateTime.utc_now(:second)
        })

      assert has_element?(view, "h1", "Your seat was released")

      assert has_element?(
               view,
               "p",
               "Your payment arrived after the seat held for you was released, and the session had no room left. Your payment is being refunded."
             )

      refute has_element?(view, "a", "Return to booking")
    end

    test "a hold released with its cancelled session reads as cancelled",
         %{conn: conn, user: user} do
      view =
        seat_return_page(conn, user, %{status: :released, released_reason: :meeting_cancelled})

      assert has_element?(view, "h1", "Booking cancelled")

      assert has_element?(
               view,
               "p",
               "This booking has been cancelled, so it won't be going ahead."
             )
    end

    test "a hold whose payment failed reads as not completed", %{conn: conn, user: user} do
      view =
        seat_return_page(conn, user, %{status: :released, released_reason: :failed}, %{
          status: :failed
        })

      assert has_element?(view, "h1", "Payment not completed")
      assert has_element?(view, "p", "Your booking is not confirmed.")
      assert has_element?(view, "a[href='/paid-seat/group-class']", "Return to booking")
    end

    @tag :capture_log
    test "returning through the cancel URL releases the hold", %{conn: conn, profile: profile} do
      %{cancel_url: cancel_url, hold_id: hold_id} = book_seat_to_checkout(conn, profile)
      %{meeting_id: meeting_id} = SeatHolds.get(hold_id)
      assert Seats.seats_occupied(meeting_id) == 2
      test_pid = self()

      StripeStub.expect(:expire_checkout_session, fn %{path: path, headers: headers} ->
        assert path =~ @session_id
        send(test_pid, {:expired_session, headers["stripe-account"]})
        StripeFixtures.object("checkout_session_expired", %{"id" => @session_id})
      end)

      {:ok, view, _html} = live(conn, cancel_url)
      shell = "[data-testid='quill-payment-cancelled']"
      assert has_element?(view, "#{shell} h1", "Payment cancelled")
      assert has_element?(view, "#{shell} a[href='/paid-seat/group-class']", "Return to booking")

      # Leaving the checkout ends it at Stripe; Stripe's
      # `checkout.session.expired` webhook then releases the hold.
      assert_receive {:expired_session, "acct_RETURN"}
      assert %{status: :held} = SeatHolds.get(hold_id)

      payment = BookingPayments.payment_for_seat_hold(hold_id)
      assert :ok = CheckoutSessionExpired.handle(seat_expired_event(payment))

      assert %{status: :released} = SeatHolds.get(hold_id)
      assert Seats.seats_occupied(meeting_id) == 0
    end

    # Without the signed return token the visitor only reads the page.
    test "the cancel page without its token leaves the checkout open",
         %{conn: conn, profile: profile} do
      %{hold_id: hold_id} = book_seat_to_checkout(conn, profile)

      {:ok, view, _html} = live(conn, "/themes/quill/payment-cancelled/seat/#{hold_id}")

      assert has_element?(view, "[data-testid='quill-payment-cancelled'] h1", "Payment cancelled")
      assert %{status: :held} = SeatHolds.get(hold_id)
    end
  end

  # Mounts the processing page of a hold on a confirmed group session that
  # others booked: the hold and its payment are the only rows that differ.
  defp seat_return_page(conn, user, hold_attrs, payment_attrs \\ %{status: :pending}) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
    start = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

    meeting =
      insert(:group_meeting,
        organizer_user_id: user.id,
        meeting_type_ref: meeting_type,
        start_time: start,
        end_time: DateTime.add(start, 30, :minute),
        capacity: 5,
        status: :confirmed
      )

    insert(:participant, meeting: meeting, email: "on-time@example.com")

    hold =
      insert(:seat_hold, Map.merge(%{meeting: meeting, email: "late@example.com"}, hold_attrs))

    insert(
      :booking_payment,
      Map.merge(
        %{
          meeting: meeting,
          seat_hold_id: hold.id,
          seat_payment: true,
          seats: hold.seats,
          amount_cents: 2000 * hold.seats,
          host_user_id: user.id,
          stripe_account_id: "acct_RETURN",
          stripe_checkout_session_id: "cs_SEAT_#{hold.id}"
        },
        payment_attrs
      )
    )

    {:ok, view, _html} =
      live(conn, "/themes/quill/payment-processing/seat/#{hold.id}?session_id=cs_SEAT_#{hold.id}")

    view
  end

  # Books a seat and one guest on the paid group type at the top level,
  # asserts the visitor is sent to Stripe Checkout, and returns the return
  # URLs as paths with the hold they are keyed by.
  defp book_seat_to_checkout(conn, profile) do
    test_pid = self()

    StripeStub.expect(:create_checkout_session, fn %{form: form} ->
      send(test_pid, {:checkout_session, form})

      StripeFixtures.object("checkout_session_payment", %{
        "id" => @session_id,
        "url" => @checkout_url
      })
    end)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=UTC")
    BookingDriver.book(view, meeting_type: "group-class", until: :attendee)

    view |> element("[data-testid='guest-toggle']") |> render_click()
    view |> form("#guest-add-form", %{"guest_email" => "friend@example.com"}) |> render_submit()

    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay Pat", "email" => "pat@example.com", "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    assert_received {:checkout_session, params}

    success_url =
      params["success_url"] |> String.replace("{CHECKOUT_SESSION_ID}", @session_id) |> path_of()

    %{"hold_id" => hold_id} =
      Regex.named_captures(
        ~r{^/themes/quill/payment-processing/seat/(?<hold_id>[^/?]+)\?session_id=#{@session_id}$},
        success_url
      ) || flunk("expected a seat processing URL, got #{success_url}")

    %{success_url: success_url, cancel_url: path_of(params["cancel_url"]), hold_id: hold_id}
  end

  defp seat_completed_event(payment) do
    seat_event(payment, "checkout.session.completed", %{
      "payment_intent" => "pi_SEAT_RETURN",
      "payment_status" => "paid",
      "amount_total" => payment.amount_cents,
      "currency" => payment.currency
    })
  end

  defp seat_expired_event(payment) do
    seat_event(payment, "checkout.session.expired", %{
      "payment_status" => "unpaid",
      "status" => "expired"
    })
  end

  defp seat_event(payment, type, object) do
    %{
      "id" => "evt_#{type}_#{payment.id}",
      "type" => type,
      "account" => "acct_RETURN",
      "created" => System.os_time(:second),
      "data" => %{
        "object" =>
          Map.merge(
            %{
              "id" => payment.stripe_checkout_session_id,
              "client_reference_id" => "seat_hold:" <> payment.seat_hold_id,
              "metadata" => %{"seat_hold_id" => payment.seat_hold_id}
            },
            object
          )
      }
    }
  end

  # An organiser on `theme_id` with one paid meeting type, "Paid Consult",
  # and a Stripe account that takes charges.
  defp seed_paid_organiser(theme_id, username, profile_attrs \\ []) do
    %{user: user, profile: profile} =
      seed_organiser(theme_id, username,
        profile: profile_attrs,
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

    profile
  end

  # Books the paid meeting type on the organiser's page through the markup
  # contract, asserts the visitor is sent to Stripe Checkout, and returns
  # the return URLs the checkout session was created with, as paths.
  defp book_to_checkout(conn, profile) do
    StripeStub.expect(:create_checkout_session, 1, fn request ->
      assert request.headers["stripe-account"] == "acct_RETURN"

      StripeFixtures.object("checkout_session_payment", %{
        "id" => @session_id,
        "url" => @checkout_url
      })
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
    assert [%{form: form}] = StripeStub.requests(:create_checkout_session)

    %{
      success_url:
        form["success_url"]
        |> String.replace("{CHECKOUT_SESSION_ID}", @session_id)
        |> path_of(),
      cancel_url: path_of(form["cancel_url"])
    }
  end

  defp path_of(url) do
    base = Endpoint.url()
    assert String.starts_with?(url, base), "expected #{url} to start with #{base}"
    String.replace_prefix(url, base, "")
  end
end
