defmodule TymeslotWeb.Live.Themes.MeetingManagementThemeTest do
  @moduledoc """
  Which theme the cancel and reschedule pages show. They resolve it as the
  booking pages do (`?theme=`, then the organiser's theme, each only when the
  catalogue knows it, then the default), and the page, its stylesheet and its
  customisation all follow that one answer.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :themes
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.ThemeTestMatrix

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  defp organiser_with_theme(theme_id) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "host-#{System.unique_integer([:positive])}",
        booking_theme: theme_id
      )

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        status: "confirmed"
      )

    {profile, meeting}
  end

  defp assert_theme(conn, path, theme) do
    html = conn |> get(path) |> html_response(200)
    assert html =~ ~s(href="/assets/scheduling-theme-#{theme.slug}.css")
    assert html =~ theme.wrapper_class

    {:ok, view, _html} = live(conn, path)
    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.theme_id == theme.id
    # Each theme's spec has its own defaults, so the tokens tell the themes'
    # customisations apart.
    assert assigns.theme_tokens == ThemeCustomizations.tokens(theme.id, nil)
  end

  # Each theme is requested over an organiser who uses another one, so the
  # page can only show it by honouring `?theme=`.
  defp another_theme(theme), do: Enum.find(ThemeTestMatrix.all(), &(&1.id != theme.id))

  for action <- ["cancel", "reschedule"], theme <- ThemeTestMatrix.all() do
    test "the #{action} page follows ?theme=#{theme.id} (#{theme.name}) in its page, stylesheet and customisation",
         %{conn: conn} do
      theme = ThemeTestMatrix.fetch!(unquote(theme.id))
      organisers = another_theme(theme)
      {profile, meeting} = organiser_with_theme(organisers.id)
      path = "/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}"

      assert_theme(conn, path, organisers)
      assert_theme(conn, path <> "?theme=#{theme.id}", theme)
    end
  end

  for action <- ["cancel", "reschedule"] do
    test "the #{action} page falls back to the default theme when the organiser's has left the catalogue",
         %{conn: conn} do
      {profile, meeting} = organiser_with_theme("9")
      path = "/#{profile.username}/meeting/#{meeting.uid}/#{unquote(action)}"

      assert_theme(conn, path, ThemeTestMatrix.fetch!(Catalog.default_id()))
    end
  end
end
