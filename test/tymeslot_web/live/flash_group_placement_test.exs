defmodule TymeslotWeb.Live.FlashGroupPlacementTest do
  @moduledoc """
  Pins the rule that exactly one flash group renders on every LiveView surface.

  The `app` layout (`components/layouts/app.html.heex`) is the single owner: it
  is the inner layout for every `use TymeslotWeb, :live_view` module, and it
  sits inside the LiveView's own rendered tree, so it is the only placement a
  live `put_flash/3` can ever reach. Root layouts and page templates must not
  render a group of their own.

  Each test counts occurrences of the flash text twice: once in the static HTTP
  render (which includes the root layout) and once in the LiveView tree alone.
  A second group anywhere pushes the static count to two; deleting the only
  group drops one or both counts to zero, and a group that has drifted into a
  root layout drops the live count to zero while the static count stays at one.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :ui
  @moduletag :live
  @moduletag :integration

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Controller
  alias Tymeslot.Infrastructure.DashboardCache

  @flash_message "Flash placement canary"

  setup_all do
    case Process.whereis(DashboardCache) do
      nil -> start_supervised!(DashboardCache)
      _pid -> :ok
    end

    :ok
  end

  describe "public booking page (scheduling_root layout)" do
    setup %{conn: conn} do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "flashcanary")

      Mox.stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _integration,
                                                                      _range_start,
                                                                      _range_end ->
        {:ok, []}
      end)

      insert(:calendar_integration, user: user, provider: "google", is_active: true)

      insert(:meeting_type,
        user: user,
        name: "Test Meeting",
        duration_minutes: 30,
        is_active: true
      )

      {:ok, conn: with_flash(conn), username: profile.username}
    end

    test "renders the flash exactly once", %{conn: conn, username: username} do
      {:ok, view, static_html} = live(conn, "/#{username}")

      assert count_flash(static_html) == 1
      assert count_flash(render(view)) == 1
    end
  end

  describe "dashboard (root layout plus page template)" do
    setup %{conn: conn} do
      DashboardCache.clear_all()

      user =
        insert(:user,
          onboarding_completed_at: DateTime.utc_now(),
          dashboard_tour_seen_at: DateTime.utc_now()
        )

      insert(:profile, user: user, username: "flashcanaryhost", full_name: "Flash Canary")

      conn =
        conn
        |> init_test_session(%{})
        |> log_in_user(user)
        |> with_flash()

      {:ok, conn: conn}
    end

    test "renders the flash exactly once", %{conn: conn} do
      {:ok, view, static_html} = live(conn, ~p"/dashboard/overview")

      assert count_flash(static_html) == 1
      assert count_flash(render(view)) == 1
    end
  end

  describe "auth pages (root layout plus auth card)" do
    setup %{conn: conn} do
      {:ok, conn: with_flash(conn)}
    end

    test "renders the flash exactly once", %{conn: conn} do
      {:ok, view, static_html} = live(conn, ~p"/auth/reset-password")

      assert count_flash(static_html) == 1
      assert count_flash(render(view)) == 1
    end
  end

  defp with_flash(conn) do
    conn
    |> init_test_session(%{})
    |> Controller.fetch_flash()
    |> Controller.put_flash(:info, @flash_message)
  end

  defp count_flash(html), do: length(String.split(html, @flash_message)) - 1
end
