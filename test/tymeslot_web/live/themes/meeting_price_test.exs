defmodule TymeslotWeb.Live.Themes.MeetingPriceTest do
  @moduledoc """
  A paid meeting type's price on Quill's and Rhythm's booking pages: beside
  the type in the overview list, on the length step of a type offering
  several lengths, in the heading of its schedule step, and on the details
  step the booker submits from, in the organiser's currency
  (`MeetingPrice.hint/1`). A free type, and a reschedule, shows no price, and
  an embedded paid booking's confirmation says what was paid, in a line the
  guest's language words around the amount.

  The organiser's account is in a legacy currency (RON: still charged, but
  outside the allowlist new prices are set in), so a price shown in the
  fallback currency instead of the one checkout charges fails every test.
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
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @price "[data-testid='meeting-price']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # A paid type is offered, and so priced, only while the organiser can
    # take payments (`Tymeslot.MeetingTypes.PaymentAccess`).
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

  for {theme_id, theme} <- [{"1", "quill"}, {"2", "rhythm"}] do
    describe theme do
      setup do
        %{user: user, profile: profile, meeting_types: [paid, free, several]} =
          seed_organiser(unquote(theme_id), "priced-#{unquote(theme)}",
            types: [
              [
                name: "Paid Consult",
                duration_minutes: 45,
                payment_required: true,
                price_cents: 4500
              ],
              [name: "Quick Chat", duration_minutes: 30],
              [
                name: "Flexible Consult",
                duration_minutes: 30,
                extra_lengths_minutes: [60],
                payment_required: true,
                price_cents: 4500
              ]
            ],
            profile: [allowed_embed_domains: ["embedder.test"]]
          )

        insert(:connect_account,
          user: user,
          stripe_account_id: "acct_PRICE",
          default_currency: "ron",
          charges_enabled: true
        )

        %{
          user: user,
          profile: profile,
          paid_type: paid,
          paid: MeetingTypes.effective_slug(paid),
          free: MeetingTypes.effective_slug(free),
          several: MeetingTypes.effective_slug(several)
        }
      end

      test "the overview prices the paid type and only that one",
           %{conn: conn, profile: profile, paid: paid, free: free} do
        {:ok, view, _html} = live(conn, "/#{profile.username}")

        assert has_element?(
                 view,
                 "[data-fact='meeting_type'][data-value='#{paid}'] #{@price}",
                 "RON 45.00"
               )

        refute has_element?(view, "[data-fact='meeting_type'][data-value='#{free}'] #{@price}")
      end

      test "the schedule and details steps of a paid type show its price",
           %{conn: conn, profile: profile, paid: paid} do
        {:ok, view, _html} = live(conn, "/#{profile.username}")
        BookingDriver.choose_meeting_type(view, paid)
        if step(view) == :overview, do: BookingDriver.continue(view)

        assert step(view) == :schedule
        assert has_element?(view, @price, "RON 45.00")

        BookingDriver.book(view, until: :attendee, meeting_type: paid)

        assert step(view) == :booking
        assert has_element?(view, @price, "RON 45.00")
      end

      # One price covers every length (`Tymeslot.MeetingTypes.Lengths`), so the
      # step between the overview and the calendar shows it too.
      test "the length step of a paid type offering two lengths shows its price",
           %{conn: conn, profile: profile, several: several} do
        {:ok, view, _html} = live(conn, "/#{profile.username}")
        BookingDriver.choose_meeting_type(view, several)
        if step(view) == :overview, do: BookingDriver.continue(view)

        assert BookingDriver.lengths(view) == ["30", "60"]
        assert has_element?(view, "[data-testid='length-step'] #{@price}", "RON 45.00")

        BookingDriver.choose_length(view, 60)
        BookingDriver.continue(view)

        assert step(view) == :schedule
        assert has_element?(view, @price, "RON 45.00")
      end

      # Moving a booking is never charged again, so the price that was paid
      # for it must not read as a price for the move.
      test "rescheduling a paid booking shows no price",
           %{conn: conn, user: user, profile: profile, paid_type: paid_type} do
        start = DateTime.utc_now() |> DateTime.add(3, :day) |> DateTime.truncate(:second)

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            meeting_type_id: paid_type.id,
            start_time: start,
            end_time: DateTime.add(start, 45, :minute),
            duration: 45,
            attendee_timezone: "UTC",
            status: "confirmed"
          )

        {:ok, view, _html} =
          live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

        assert :sys.get_state(view.pid).socket.assigns.is_rescheduling == true

        if step(view) == :overview do
          refute has_element?(view, @price)
          BookingDriver.continue(view)
        end

        assert step(view) == :schedule
        refute has_element?(view, @price)

        BookingDriver.book(view, until: :attendee)

        assert step(view) == :booking
        refute has_element?(view, @price)
      end

      test "a free type's details step shows no price",
           %{conn: conn, profile: profile, free: free} do
        {:ok, view, _html} = live(conn, "/#{profile.username}")

        BookingDriver.book(view, until: :attendee, meeting_type: free)

        assert step(view) == :booking
        assert has_element?(view, "[data-fact='attendee']")
        refute has_element?(view, @price)
      end

      @tag :capture_log
      test "an embedded paid booking's confirmation says what was paid",
           %{conn: conn, profile: profile, paid: paid} do
        view = pay_embedded(conn, "/#{profile.username}?embed=1", paid)

        assert has_element?(view, "[data-testid='confirmation-paid']", "RON 45.00")
      end

      # Quill writes what was paid as one sentence: the translation decides
      # where the amount goes, and the amount keeps its own emphasis there.
      if theme == "quill" do
        @tag :capture_log
        test "the paid line is worded around the amount in the guest's language",
             %{conn: conn, profile: profile, paid: paid} do
          view = pay_embedded(conn, "/#{profile.username}?embed=1&locale=de", paid)

          line = view |> render() |> Floki.parse_document!()
          amount = line |> Floki.find("[data-testid='confirmation-paid'] p span") |> Floki.text()
          text = line |> Floki.find("[data-testid='confirmation-paid'] p") |> Floki.text()

          assert amount =~ "45,00"
          assert String.trim(text) == "#{amount} bezahlt"
        end
      end
    end
  end

  # Stripe Checkout cannot be framed, so an embedded booker waits for the
  # payment in place and reaches the confirmation on the `:paid` broadcast.
  # The referer is the parent page `allowed_embed_domains` admits.
  defp pay_embedded(conn, path, meeting_type) do
    expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
      {:ok, %{id: "cs_PRICE", url: "https://checkout.stripe.com/cs_PRICE"}}
    end)

    conn = put_req_header(conn, "referer", "https://embedder.test/page")
    {:ok, view, _html} = live(conn, path)
    assert :sys.get_state(view.pid).socket.assigns[:embedded] == true

    BookingDriver.book(view, until: :submitted, meeting_type: meeting_type)
    _drain = :sys.get_state(view.pid)

    refute has_element?(view, "[data-testid='confirmation-paid']")
    meeting = :sys.get_state(view.pid).socket.assigns.awaiting_payment_meeting

    Phoenix.PubSub.broadcast(Tymeslot.PubSub, "meeting_payment:#{meeting.id}", :paid)
    _drain = :sys.get_state(view.pid)

    view
  end

  defp step(view), do: :sys.get_state(view.pid).socket.assigns.current_state
end
