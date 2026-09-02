defmodule TymeslotWeb.Dashboard.Automation.BookingApiSectionTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :integration
  @moduletag :automation

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.BookingApi
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Profiles

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker
    )

    ConfigTestHelpers.setup_config(:tymeslot,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    %{conn: log_in_user(conn, user), user: user}
  end

  defp token(user_id) do
    {:ok, profile} = Profiles.get_or_create_profile(user_id)
    profile.booking_api_token
  end

  describe "the booking API card" do
    test "starts closed, offering to open the endpoint", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")

      assert render(view) =~ "Enable booking API"
      assert is_nil(token(user.id))
    end

    test "enabling it mints a token and shows it with the endpoint", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")

      html = view |> element("button", "Enable booking API") |> render_click()

      minted = token(user.id)
      assert byte_size(minted) > 0
      assert html =~ minted
      assert html =~ "/api/v1/bookings"
    end

    test "regenerating replaces the token shown", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button", "Enable booking API") |> render_click()
      first = token(user.id)

      html = view |> element("button", "Regenerate token") |> render_click()
      second = token(user.id)

      refute second == first
      assert html =~ second
      refute html =~ first
    end

    test "disabling clears the token and closes the endpoint", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")
      view |> element("button", "Enable booking API") |> render_click()
      minted = token(user.id)

      html = view |> element("button", "Disable booking API") |> render_click()

      assert is_nil(token(user.id))
      refute html =~ minted
      assert html =~ "Enable booking API"
      assert {:error, :not_found} = BookingApi.authenticate(minted)
    end
  end
end
