defmodule TymeslotWeb.Live.Themes.BookerHookClassesTest do
  @moduledoc """
  The shared embed rules (assets/css/scheduling/shared/embed.css) target
  hook classes rather than each theme's own container names, so every theme
  must mark its page grid and its card with them.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  for theme_id <- ThemeTestMatrix.registered_ids() do
    test "theme #{theme_id} marks its page grid and card with the embed hooks", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme_id), "hooks-#{unquote(theme_id)}", "UTC")

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

      assert has_element?(view, ".booker-page")
      assert has_element?(view, ".booker-card")
    end
  end
end
