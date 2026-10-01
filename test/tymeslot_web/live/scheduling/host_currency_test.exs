defmodule TymeslotWeb.Live.Scheduling.HostCurrencyTest do
  @moduledoc """
  The booking page holds the currency the organiser's paid meeting types are
  priced in (`:host_currency`), which a theme shows a price with
  (`BookingText.price_label/2`). An organiser who offers no paid type costs
  the page no lookup, and the assign is `nil`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :payments

  import Mox
  import Tymeslot.Factory
  import Tymeslot.ThemeBookingFlowHelpers

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

  test "is the organiser's pricing currency when they offer a paid type",
       %{conn: conn, user: user, profile: profile} do
    insert(:connect_account, user: user, default_currency: "chf")

    insert(:meeting_type,
      user: user,
      name: "Paid Session",
      payment_required: true,
      price_cents: 4500
    )

    assert host_currency(conn, profile) == "chf"
  end

  test "is nil while every meeting type is free", %{conn: conn, user: user, profile: profile} do
    insert(:connect_account, user: user, default_currency: "chf")

    assert host_currency(conn, profile) == nil
  end
end
