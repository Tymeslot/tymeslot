defmodule TymeslotWeb.Live.Scheduling.HostCurrencyTest do
  @moduledoc """
  The booking page holds the currency the organiser's paid meeting types are
  priced in (`:host_currency`), which a theme shows a price with
  (`BookingText.price_label/3`). An organiser who offers no paid type costs
  the page no lookup, and the assign is `nil`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :payments

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    seed_booking_account("1", "currency-organiser", "Etc/UTC")
  end

  defp host_currency(conn, profile) do
    {:ok, view, _html} = live(conn, "/#{profile.username}")
    :sys.get_state(view.pid).socket.assigns.host_currency
  end

  # The paid type is offered, and so priced, only while the organiser can
  # take payments (`Tymeslot.MeetingTypes.PaymentAccess`).
  test "is the organiser's pricing currency when they offer a paid type",
       %{conn: conn, user: user, profile: profile} do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    insert(:connect_account, user: user, default_currency: "chf", charges_enabled: true)

    insert(:meeting_type,
      user: user,
      name: "Paid Session",
      payment_required: true,
      price_cents: 4500
    )

    assert host_currency(conn, profile) == "chf"
  end

  # Checkout charges the account's own currency, so a price in the fallback
  # would read as a different amount from the one taken.
  test "is the account's currency even outside the allowlist new prices are set in",
       %{conn: conn, user: user, profile: profile} do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )

    insert(:connect_account, user: user, default_currency: "ron", charges_enabled: true)

    insert(:meeting_type,
      user: user,
      name: "Paid Session",
      payment_required: true,
      price_cents: 4500
    )

    assert host_currency(conn, profile) == "ron"
  end

  test "is nil while every meeting type is free", %{conn: conn, user: user, profile: profile} do
    insert(:connect_account, user: user, default_currency: "chf")

    assert host_currency(conn, profile) == nil
  end
end
