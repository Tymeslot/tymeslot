defmodule TymeslotWeb.Live.Themes.BookerHookClassesTest do
  @moduledoc """
  The obligations every booking page meets, whatever the theme's layout:
  one outermost element marked `data-booker-root` (the shared embed rules
  size it), and inside it the organiser's colours, the language switcher and
  the configured theme extensions, all rendered by `ThemeShell`, plus the
  `booker-card` hook on the theme's card.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Test.BrandingFooterStub
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

  setup do
    ConfigTestHelpers.setup_config(:tymeslot, :theme_extensions, [{BrandingFooterStub, :banner}])
  end

  for theme_id <- ThemeTestMatrix.registered_ids() do
    test "theme #{theme_id} carries the shell obligations inside one booker root", %{conn: conn} do
      %{profile: profile} =
        seed_booking_account(unquote(theme_id), "hooks-#{unquote(theme_id)}", "UTC")

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
      doc = view |> render() |> Floki.parse_fragment!()

      assert length(Floki.find(doc, "[data-booker-root]")) == 1
      assert Floki.find(doc, "[data-booker-root] .lang-switcher") != []
      assert Floki.find(doc, "[data-booker-root] .branding-footer") != []
      assert Floki.find(doc, "[data-booker-root] .booker-card") != []

      # The colours are written whenever the theme's tokens carry any.
      has_vars? = ThemeCustomizations.tokens(unquote(theme_id), nil).vars != %{}
      styled? = Floki.find(doc, "[data-booker-root] > style") != []
      assert styled? == has_vars?
    end
  end
end
