defmodule TymeslotWeb.Dashboard.AnnouncementModalTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :dashboard

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Plug.Conn
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Announcements
  alias Tymeslot.Announcements.AnnouncementQueries
  alias Tymeslot.AnnouncementsTestCatalog
  alias Tymeslot.AuthTestHelpers

  setup %{conn: conn} do
    previous = Application.get_env(:tymeslot, :announcement_catalogs, [])

    Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsTestCatalog])

    on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)

    {:ok, conn: conn}
  end

  defp pre_existing_user(opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, ~N[2025-12-01 00:00:00])

    user =
      insert(:user,
        inserted_at: inserted_at,
        onboarding_completed_at: DateTime.utc_now()
      )

    insert(:profile, user: user)
    user
  end

  defp log_in(conn, user) do
    conn
    |> PlugTest.init_test_session(%{})
    |> Conn.fetch_session()
    |> AuthTestHelpers.log_in_user(user)
  end

  describe "/dashboard with no unseen announcements" do
    test "does not render the modal", %{conn: conn} do
      user = pre_existing_user()
      Announcements.mark_seen!(user, "test_alpha")
      Announcements.mark_seen!(user, "test_beta")

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "announcement-modal-modal"
    end
  end

  describe "/dashboard with unseen announcements" do
    test "renders the first announcement and the step indicator", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Alpha"
      assert html =~ "1 / 2"
    end

    test "Next advances and marks the prior announcement seen", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element(~s|button[phx-click="next"]|)
      |> render_click()

      rendered = render(view)
      assert rendered =~ "Beta"
      assert rendered =~ "2 / 2"
      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_alpha"]
    end

    test "CTA on the last item closes the modal and marks all seen", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element(~s|button[phx-click="next"]|) |> render_click()
      view |> element(~s|button[phx-click="cta"]|) |> render_click()

      keys = Enum.sort(AnnouncementQueries.seen_keys_for(user.id))
      assert keys == ["test_alpha", "test_beta"]
    end

    test "closing while still on item 1 leaves item 2 unseen for next login", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element(~s|.modal-header button[aria-label="Close modal"]|) |> render_click()

      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_alpha"]

      {:ok, _view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Beta"
    end
  end

  describe "/dashboard for a user who signed up after every announcement" do
    test "does not render the modal", %{conn: conn} do
      user = pre_existing_user(inserted_at: ~N[2026-04-01 00:00:00])

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "announcement-modal-modal"
    end
  end
end
