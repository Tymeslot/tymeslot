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

  # A paid organiser with one 30-minute type, a connected Stripe account
  # (so a price can be shown) and `type_attrs` on the type.
  defp seed_paid(theme, username, type_attrs \\ []) do
    seeded =
      seed_organiser(theme.id, username,
        types: [
          [
            name: "Paid Consult",
            duration_minutes: 30,
            payment_required: true,
            price_cents: 5000
          ] ++ type_attrs
        ]
      )

    insert(:connect_account,
      user: seeded.user,
      stripe_account_id: "acct_SHOW",
      default_currency: "usd",
      charges_enabled: true
    )

    price =
      BookingText.price_label(
        %{payment_required: true, price_cents: 5000},
        MeetingPayments.host_currency(seeded.user.id),
        "en"
      )

    Map.put(seeded, :price, price)
  end

  # The submit of a gated type: Folio words its own, the rest share one.
  defp request_label(:folio), do: "Request this time"
  defp request_label(_shared), do: "Request meeting"

  # The submit of a reschedule: Paper words its own, the rest share one.
  defp reschedule_label(:paper), do: "Reschedule meeting"
  defp reschedule_label(_shared), do: "Reschedule Meeting"

  # The submit's `aria-describedby` and the price element's id, as rendered.
  # Quill also links the "required fields" hint while the form is incomplete,
  # which is not what these tests are about.
  defp described_by(view) do
    view
    |> element("[data-testid='submit-booking']")
    |> render()
    |> attribute("aria-describedby")
    |> without_required_fields_hint()
  end

  defp without_required_fields_hint(nil), do: nil

  defp without_required_fields_hint(ids) do
    case String.split(ids) -- ["submit-booking-hint"] do
      [] -> nil
      kept -> Enum.join(kept, " ")
    end
  end

  defp attribute(html, name) do
    html |> Floki.parse_fragment!() |> Floki.attribute(name) |> List.first()
  end

  defp price_id(view) do
    view |> element("[data-testid='submit-price']") |> render() |> attribute("id")
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

      assert price_id(view) == "submit-price-amount"
      assert described_by(view) == price_id(view)
    end

    @tag :capture_log
    test "theme #{theme.slug}: a paid type that needs approval shows the price on a request",
         %{conn: conn} do
      %{profile: profile, price: price} =
        seed_paid(unquote(Macro.escape(theme)), "paid-gated-#{unquote(theme.slug)}",
          requires_approval: true
        )

      {:ok, view, _html} = live(conn, "/#{profile.username}")
      BookingDriver.book(view, until: :attendee)

      assert has_element?(view, "[data-testid='submit-price']", price)

      assert has_element?(
               view,
               "[data-testid='submit-booking']",
               request_label(unquote(theme.key))
             )

      assert described_by(view) == price_id(view)
    end

    @tag :capture_log
    test "theme #{theme.slug}: rescheduling a paid booking shows no price", %{conn: conn} do
      %{user: user, profile: profile, meeting_types: [type]} =
        seed_paid(unquote(Macro.escape(theme)), "paid-move-#{unquote(theme.slug)}")

      start_time = DateTime.utc_now() |> DateTime.add(2, :day) |> DateTime.truncate(:second)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          meeting_type_id: type.id,
          duration: 30,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        )

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?reschedule_meeting_uid=#{meeting.uid}")

      BookingDriver.book(view, until: :attendee)

      assert has_element?(
               view,
               "[data-testid='submit-booking']",
               reschedule_label(unquote(theme.key))
             )

      refute has_element?(view, "[data-testid='submit-price']")
      assert described_by(view) == nil
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
      assert has_element?(view, "[data-testid='submit-booking']")
      assert described_by(view) == nil
    end
  end
end
