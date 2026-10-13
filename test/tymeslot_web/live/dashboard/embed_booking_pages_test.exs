defmodule TymeslotWeb.Dashboard.EmbedBookingPagesTest do
  use TymeslotWeb.LiveCase, async: true

  @moduletag :dashboard

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Phoenix.LiveView.Socket
  alias Tymeslot.Embed.Token
  alias Tymeslot.Repo
  alias TymeslotWeb.Hooks.EmbedAuthHook

  setup :setup_dashboard_user_with_theme

  setup %{profile: profile} do
    %{profile: profile |> Changeset.change(username: "joern") |> Repo.update!()}
  end

  test "without booking pages there is no picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

    refute has_element?(view, "#embed-page-picker")
  end

  test "the picker names each page and its address", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso", name: "Einfach ISO")
    {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

    assert has_element?(view, "#embed-page-picker option[value='profile']", "/joern")

    assert has_element?(
             view,
             "#embed-page-picker option[value='#{page.id}']",
             "Einfach ISO · /einfachiso"
           )
  end

  test "the snippet follows the chosen page", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    {:ok, view, html} = live(conn, ~p"/dashboard/embed")

    assert html =~ ~r/data-username=(&quot;|")joern/

    html =
      view
      |> form("#embed-page-picker", %{"page" => to_string(page.id)})
      |> render_change()

    assert html =~ ~r/data-username=(&quot;|")einfachiso/
  end

  test "choosing the profile again returns to the username", %{conn: conn, profile: profile} do
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

    view |> form("#embed-page-picker", %{"page" => to_string(page.id)}) |> render_change()
    html = view |> form("#embed-page-picker", %{"page" => "profile"}) |> render_change()

    assert html =~ ~r/data-username=(&quot;|")joern/
  end

  test "an unknown page value changes nothing", %{conn: conn, profile: profile} do
    insert(:booking_page, profile: profile, slug: "einfachiso")
    {:ok, view, _html} = live(conn, ~p"/dashboard/embed")

    html =
      view
      |> element("#embed-page-picker")
      |> render_change(%{"page" => "999999999"})

    assert html =~ ~r/data-username=(&quot;|")joern/
  end

  describe "embed auth under a page address" do
    test "lets the page address through from an allowed domain", %{profile: profile} do
      profile
      |> Changeset.change(allowed_embed_domains: ["example.com"])
      |> Repo.update!()

      insert(:booking_page, profile: profile, slug: "einfachiso")

      socket = %Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        endpoint: TymeslotWeb.Endpoint,
        transport_pid: self(),
        private: %{connect_info: %{}}
      }

      token = Token.sign("einfachiso", "https://example.com")

      assert {:cont, updated} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => token}, socket)

      assert updated.assigns.embedded == true

      other = Token.sign("einfachiso", "https://evil.com")

      assert {:halt, _socket} =
               EmbedAuthHook.on_mount(:default, %{}, %{"embed_token" => other}, socket)
    end
  end
end
