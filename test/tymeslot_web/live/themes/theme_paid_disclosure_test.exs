defmodule TymeslotWeb.Live.Themes.ThemePaidDisclosureTest do
  @moduledoc """
  On every shipped theme a paid meeting type says what it costs before the
  visitor commits: its price on its entry and beside the submit, and a
  submit that names the payment that follows. A free type shows neither.
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
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.ThemeTestMatrix

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  for theme <- ThemeTestMatrix.all() do
    @tag :capture_log
    test "theme #{theme.slug}: a paid type names its price and the payment before the submit",
         %{conn: conn} do
      %{user: user, profile: profile} =
        seed_organiser(unquote(theme.id), "paid-show-#{unquote(theme.slug)}",
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
        stripe_account_id: "acct_SHOW",
        default_currency: "usd",
        charges_enabled: true
      )

      price =
        BookingText.price_label(
          %{payment_required: true, price_cents: 5000},
          MeetingPayments.host_currency(user.id),
          "en"
        )

      {:ok, view, _html} = live(conn, "/#{profile.username}")
      assert has_element?(view, "[data-fact='meeting_type'][data-value='paid-consult']", price)

      BookingDriver.book(view, until: :attendee)

      assert has_element?(view, "[data-testid='submit-price']", price)
      assert has_element?(view, "[data-testid='submit-booking']", "Continue to payment")
    end

    @tag :capture_log
    test "theme #{theme.slug}: a free type shows no price and no payment", %{conn: conn} do
      %{profile: profile} =
        seed_organiser(unquote(theme.id), "free-show-#{unquote(theme.slug)}",
          types: [[name: "Quick Chat", duration_minutes: 30]]
        )

      {:ok, view, _html} = live(conn, "/#{profile.username}")
      BookingDriver.book(view, until: :attendee)

      refute has_element?(view, "[data-testid='submit-price']")
      refute has_element?(view, "[data-testid='submit-booking']", "Continue to payment")
    end
  end
end
