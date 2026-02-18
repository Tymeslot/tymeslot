defmodule TymeslotWeb.Integration.LayoutExtensionTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: false
  import Tymeslot.TestFixtures
  import Tymeslot.Factory
  import Mox
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.DatabaseQueries.ProfileQueries

  setup do
  @moduletag :utils
    verify_on_exit!()
    # Ensure theme_extensions is empty for Core tests
    old_extensions = Application.get_env(:tymeslot, :theme_extensions)
    Application.put_env(:tymeslot, :theme_extensions, [])

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user, _start, _end ->
      {:ok, []}
    end)

    on_exit(fn ->
      Application.put_env(:tymeslot, :theme_extensions, old_extensions)
    end)

    :ok
  end

  describe "Core Layout Extensions" do
    setup do
      # Ensure show_branding is false for Core tests
      ConfigTestHelpers.setup_config(:tymeslot, show_branding: false)
      :ok
    end

    test "scheduling pages render without branding in Core-only mode", %{conn: conn} do
      # Setup: Create a user with a profile and a calendar integration
      user = create_user_fixture(%{username: "coreuser"})

      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)

      ProfileQueries.update_profile(profile, %{
        username: "coreuser",
        full_name: "Core User"
      })

      insert(:calendar_integration, user: user)

      # Action: Visit the scheduling page
      conn = get(conn, "/coreuser")

      # Assert: Page renders but branding is ABSENT
      response = html_response(conn, 200)
      assert response =~ "Core User"
      refute response =~ "Scheduling powered by Tymeslot"
      refute response =~ "tymeslot.app"
    end

    test "extension hook gracefully handles custom content when configured", %{conn: conn} do
      # Setup: Inject a dummy extension
      defmodule DummyExtension do
        use Phoenix.Component
        @spec test_overlay(map()) :: Phoenix.LiveView.Rendered.t()
        def test_overlay(assigns) do
          ~H"<div id='test-extension'>Core Extension Hook Working</div>"
        end
      end

      Application.put_env(:tymeslot, :theme_extensions, [{DummyExtension, :test_overlay}])

      user = create_user_fixture(%{username: "extensionuser"})
      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      ProfileQueries.update_profile(profile, %{username: "extensionuser"})
      insert(:calendar_integration, user: user)

      # Action
      conn = get(conn, "/extensionuser")

      # Assert
      response = html_response(conn, 200)
      assert response =~ "id='test-extension'"
      assert response =~ "Core Extension Hook Working"
    end

    test "extension hook ignores invalid configuration gracefully", %{conn: conn} do
      # Setup: Inject invalid extensions
      Application.put_env(:tymeslot, :theme_extensions, [
        {NonExistentModule, :missing_func},
        {TymeslotWeb.Layouts, :non_existent_func}
      ])

      user = create_user_fixture(%{username: "safetytest"})
      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)

      ProfileQueries.update_profile(profile, %{
        username: "safetytest",
        full_name: "Safety Test User"
      })

      insert(:calendar_integration, user: user)

      # Action & Assert: Should not crash
      conn = get(conn, "/safetytest")
      assert html_response(conn, 200) =~ "Safety Test User"
    end

    test "renders multiple extensions in order", %{conn: conn} do
      defmodule MultiExt1 do
        use Phoenix.Component
        @spec r1(map()) :: Phoenix.LiveView.Rendered.t()
        def r1(assigns), do: ~H"<div id='ext1'>First Extension</div>"
      end

      defmodule MultiExt2 do
        use Phoenix.Component
        @spec r2(map()) :: Phoenix.LiveView.Rendered.t()
        def r2(assigns), do: ~H"<div id='ext2'>Second Extension</div>"
      end

      Application.put_env(:tymeslot, :theme_extensions, [
        {MultiExt1, :r1},
        {MultiExt2, :r2}
      ])

      user = create_user_fixture(%{username: "multiext"})
      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      ProfileQueries.update_profile(profile, %{username: "multiext"})
      insert(:calendar_integration, user: user)

      # Action
      conn = get(conn, "/multiext")

      # Assert: Both render in order
      response = html_response(conn, 200)
      assert response =~ "id='ext1'"
      assert response =~ "First Extension"
      assert response =~ "id='ext2'"
      assert response =~ "Second Extension"

      # Check order: ext1 should appear before ext2 in the HTML
      assert response =~ ~r/id='ext1'.*id='ext2'/s
    end

    test "extension hook ignores completely invalid config shapes gracefully", %{conn: conn} do
      # Setup: Inject garbage configuration
      Application.put_env(:tymeslot, :theme_extensions, [
        :not_a_tuple,
        123,
        {"not", "atoms"},
        {TymeslotWeb.Layouts, :non_existent_func}
      ])

      user = create_user_fixture(%{username: "garbagetest"})
      {:ok, profile} = ProfileQueries.get_by_user_id(user.id)

      ProfileQueries.update_profile(profile, %{
        username: "garbagetest",
        full_name: "Garbage Test User"
      })

      insert(:calendar_integration, user: user)

      # Action & Assert: Should not crash and should render page
      conn = get(conn, "/garbagetest")
      assert html_response(conn, 200) =~ "Garbage Test User"
    end
  end
end
