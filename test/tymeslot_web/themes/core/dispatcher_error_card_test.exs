defmodule TymeslotWeb.Themes.Core.DispatcherErrorCardTest do
  @moduledoc """
  The dispatcher's last-resort error card, shown when a theme cannot be loaded
  or raises inside a callback, is part of the visitor's booking page and so
  speaks the visitor's language, like the rest of the page.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :i18n
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.TestMocks
  alias TymeslotWeb.Themes.Core.Dispatcher

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "errorcardhost",
        booking_theme: "1",
        timezone: "Etc/UTC"
      )

    insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30, is_active: true)
    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile}
  end

  describe "a theme that cannot be loaded" do
    # `?theme=` names a theme that does not exist, so no theme context can be
    # built and the dispatcher falls back to its own card.
    @tag :capture_log
    test "shows the error card in German on a German booking page", %{
      conn: conn,
      profile: profile
    } do
      {:ok, view, _html} = live(conn, "/#{profile.username}?theme=999&locale=de")

      assert has_element?(view, "h1", "Etwas ist schiefgelaufen")

      assert render(view) =~
               "Diese Seite konnte nicht geladen werden. Bitte versuchen Sie es erneut."

      assert has_element?(view, "#theme-error-retry-button", "Seite neu laden")
    end

    @tag :capture_log
    test "shows the error card in English by default", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, "/#{profile.username}?theme=999")

      assert has_element?(view, "h1", "Something went wrong")
      assert has_element?(view, "#theme-error-retry-button", "Reload page")
    end
  end

  describe "a theme that raises inside a callback" do
    # `ErrorBoundary` records the failure as `:theme_error`; its own tests cover
    # the catching, and this pins what the dispatcher then renders for it.
    test "renders the translated error card for the recorded failure" do
      html =
        rendered_to_string(
          Dispatcher.render(%{
            theme_error: %{function: :handle_event, theme_id: "1"},
            locale: "de"
          })
        )

      assert html =~ "Etwas ist schiefgelaufen"
      assert html =~ "Diese Seite konnte nicht geladen werden. Bitte versuchen Sie es erneut."
      assert html =~ "Seite neu laden"
    end
  end
end
