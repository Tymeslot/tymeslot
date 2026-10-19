defmodule TymeslotWeb.Live.Themes.ShowcaseThemeTest do
  @moduledoc """
  The shared option groups, driven through the real routes on the test-only
  showcase theme (id "97", `test/support/showcase_theme/`): each group's
  built-in dashboard panel saves it, and a visitor's booking page shows what
  was saved; then every group at once, from the panels to one booking page.
  Page assertions read the theme's own `<style>` block (the `:root:root` one
  `ThemeStyle` writes), split into the page's variables and those for a
  visitor whose OS is in dark mode. The logo and cover panels' uploads and
  file cleanup are `LogoPanelTest` and `CoverPanelTest`.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :themes
  @moduletag :integration

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Presets

  @theme_id "97"
  @dark_media "@media (prefers-color-scheme: dark)"

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    :ok
  end

  # A signed-in organiser whose bookable page uses the showcase theme.
  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())

    profile =
      insert(:profile,
        user: user,
        username: "showcase-#{System.unique_integer([:positive])}",
        booking_theme: @theme_id
      )

    insert(:calendar_integration, user: user, is_active: true)
    insert(:meeting_type, user: user, name: "Quick Chat", duration_minutes: 30, is_active: true)

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    %{conn: conn, profile: profile}
  end

  defp customise(conn), do: live(conn, ~p"/dashboard/theme/customize/#{@theme_id}")

  defp option_button(option, field, choice),
    do:
      "button[phx-click='theme:set_option'][phx-value-option='#{option}']" <>
        "[phx-value-field='#{field}'][phx-value-choice='#{choice}']"

  defp choices(view, option, field) do
    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.attribute(
      "button[phx-value-option='#{option}'][phx-value-field='#{field}']",
      "phx-value-choice"
    )
  end

  defp saved(profile),
    do: ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id).settings

  # What a visitor's booking page sets: `{page_vars, dark_vars}`.
  defp booking_page_vars(profile, query \\ "") do
    {:ok, _view, html} = live(build_conn(), "/#{profile.username}#{query}")

    case String.split(theme_css(html), @dark_media, parts: 2) do
      [page, dark] -> {vars(page), vars(dark)}
      [page] -> {vars(page), %{}}
    end
  end

  defp theme_css(html) do
    [css] =
      html
      |> Floki.parse_document!()
      |> Floki.find("style")
      |> Enum.map(&Floki.text(&1, js: true))
      |> Enum.filter(&String.contains?(&1, ":root:root"))

    css
  end

  defp canvas_lightness("#" <> hex) do
    [r, g, b] = for <<c::binary-2 <- hex>>, do: String.to_integer(c, 16)
    if 0.299 * r + 0.587 * g + 0.114 * b > 128, do: :light, else: :dark
  end

  defp vars(css) do
    ~r/(--[a-z0-9-]+):\s*([^;]+);/
    |> Regex.scan(css, capture: :all_but_first)
    |> Map.new(fn [name, value] -> {name, value} end)
  end

  describe "accent" do
    test "its panel offers the group's presets in the group's order, the default pressed",
         %{conn: conn} do
      {:ok, view, _html} = customise(conn)

      assert has_element?(view, "[data-testid='accent-panel']")

      assert choices(view, "accent", "preset") ==
               ~w(tymeslot cobalt indigo violet rose ember emerald teal graphite)

      assert has_element?(
               view,
               option_button("accent", "preset", "tymeslot") <> "[aria-pressed='true']"
             )
    end

    test "a preset saved in the panel becomes the booking page's primary, fitted to each colour set",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = customise(conn)

      view |> element(option_button("accent", "preset", "cobalt")) |> render_click()

      assert saved(profile)["accent"] == "cobalt"

      assert has_element?(
               view,
               option_button("accent", "preset", "cobalt") <> "[aria-pressed='true']"
             )

      {page, dark} = booking_page_vars(profile)
      assert page["--theme-primary"] == "#2563eb"
      assert dark["--theme-primary"] == "#4a7eee"
    end

    test "Custom opens the colour widget on the current accent, and the widget saves a colour of the organiser's own",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = customise(conn)
      refute has_element?(view, "#custom-accent-picker")

      view |> element("button[phx-click='theme:toggle_accent_picker']") |> render_click()

      assert saved(profile)["accent"] == "#0891b2"

      assert has_element?(
               view,
               ~s(#custom-accent-picker[data-event="theme:set_option"][data-commit-params='{"field":"custom","option":"accent"}'])
             )

      view
      |> element("#custom-accent-picker")
      |> render_hook("theme:set_option", %{
        "option" => "accent",
        "field" => "custom",
        "choice" => "#123456"
      })

      assert saved(profile)["accent"] == "#123456"

      {page, _dark} = booking_page_vars(profile)
      assert page["--theme-primary"] == "#123456"
    end

    test "an embed's primary colour wins over the saved accent on the booking page",
         %{profile: profile} do
      assert {:ok, _saved} =
               ThemeCustomizations.apply_option(profile.id, @theme_id, :accent, %{
                 "field" => "preset",
                 "value" => "cobalt"
               })

      {page, dark} = booking_page_vars(profile, "?primary-color=%23e11d48")
      assert page["--theme-primary"] == "#e11d48"
      assert dark["--theme-primary"] == "#e8496c"
    end

    test "a preset the group does not list, or a malformed colour, is refused",
         %{profile: profile} do
      assert {:error, _message} =
               ThemeCustomizations.apply_option(profile.id, @theme_id, :accent, %{
                 "field" => "preset",
                 "value" => "chartreuse"
               })

      assert {:error, _message} =
               ThemeCustomizations.apply_option(profile.id, @theme_id, :accent, %{
                 "field" => "custom",
                 "value" => "#12"
               })

      assert ThemeCustomizations.get_by_profile_and_theme(profile.id, @theme_id) == nil
    end
  end

  describe "colour mode" do
    test "its panel offers light, dark and match-device, the default pressed", %{conn: conn} do
      {:ok, view, _html} = customise(conn)

      assert has_element?(view, "[data-testid='colour-mode-panel']")
      assert choices(view, "colour_mode", "mode") == ~w(light dark auto)

      assert has_element?(
               view,
               option_button("colour_mode", "mode", "auto") <> "[aria-pressed='true']"
             )
    end

    test "auto shows the tone's light set, and its dark set to a visitor whose OS is dark",
         %{profile: profile} do
      {page, dark} = booking_page_vars(profile)

      assert page["--theme-canvas"] == "#f5f5f5"
      assert page["--theme-color-scheme"] == "light dark"
      assert page["--theme-primary"] == "#07819e"
      assert dark["--theme-canvas"] == "#0e0e10"
      assert dark["--theme-primary"] == "#0891b2"
    end

    test "light, saved in the panel, leaves the dark set out of the page",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = customise(conn)

      view |> element(option_button("colour_mode", "mode", "light")) |> render_click()

      assert saved(profile)["colour_mode"] == "light"

      assert has_element?(
               view,
               option_button("colour_mode", "mode", "light") <> "[aria-pressed='true']"
             )

      {page, dark} = booking_page_vars(profile)
      assert page["--theme-canvas"] == "#f5f5f5"
      assert page["--theme-color-scheme"] == "light"
      assert dark == %{}
    end

    test "dark, saved in the panel, shows the dark set to every visitor",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = customise(conn)

      view |> element(option_button("colour_mode", "mode", "dark")) |> render_click()

      assert saved(profile)["colour_mode"] == "dark"

      {page, dark} = booking_page_vars(profile)
      assert page["--theme-canvas"] == "#0e0e10"
      assert page["--theme-surface"] == "#18181b"
      assert page["--theme-primary"] == "#0891b2"
      assert page["--theme-color-scheme"] == "dark"
      assert dark == %{}
    end

    test "light over a custom seed gives a light page, and dark a dark one", %{profile: profile} do
      assert {:ok, _saved} =
               ThemeCustomizations.apply_option(profile.id, @theme_id, :palette, %{
                 "field" => "seed",
                 "value" => "#ffee00"
               })

      for {mode, lightness} <- [{"light", :light}, {"dark", :dark}] do
        assert {:ok, _saved} =
                 ThemeCustomizations.apply_option(profile.id, @theme_id, :colour_mode, %{
                   "field" => "mode",
                   "value" => mode
                 })

        {page, _dark} = booking_page_vars(profile)
        assert page["--theme-color-scheme"] == mode
        assert canvas_lightness(page["--theme-canvas"]) == lightness, "in #{mode} mode"
      end
    end

    test "an embed's primary colour applies in either mode, fitted to it", %{profile: profile} do
      for {mode, primary} <- [{"dark", "#e8496c"}, {"light", "#e11d48"}] do
        assert {:ok, _saved} =
                 ThemeCustomizations.apply_option(profile.id, @theme_id, :colour_mode, %{
                   "field" => "mode",
                   "value" => mode
                 })

        {page, _dark} = booking_page_vars(profile, "?primary-color=%23e11d48")
        assert page["--theme-primary"] == primary, "in #{mode} mode"
      end
    end

    test "the palette panel lists the tones the showcase offers, in its order", %{conn: conn} do
      {:ok, view, _html} = customise(conn)

      assert choices(view, "palette", "scheme") == ~w(neutral cool warm)
    end
  end

  describe "font" do
    test "its panel offers the group's fonts in the group's order, the default pressed",
         %{conn: conn} do
      {:ok, view, _html} = customise(conn)

      assert has_element?(view, "[data-testid='font-panel']")
      assert choices(view, "font", "font") == ~w(system inter plex editorial)

      assert has_element?(
               view,
               option_button("font", "font", "system") <> "[aria-pressed='true']"
             )
    end

    test "a font saved in the panel points the booking page at its stacks",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = customise(conn)

      view |> element(option_button("font", "font", "plex")) |> render_click()

      assert saved(profile)["font"] == "plex"

      {page, dark} = booking_page_vars(profile)
      assert page["--theme-font-family"] == "var(--font-stack-plex)"
      assert page["--theme-font-heading"] == "var(--font-heading-plex)"
      refute Map.has_key?(dark, "--theme-font-family")
    end

    test "a font the group does not offer is refused", %{profile: profile} do
      assert {:error, _message} =
               ThemeCustomizations.apply_option(profile.id, @theme_id, :font, %{
                 "field" => "font",
                 "value" => "classic"
               })
    end
  end

  describe "radius" do
    test "its panel offers sharp, soft and round, the default pressed", %{conn: conn} do
      {:ok, view, _html} = customise(conn)

      assert has_element?(view, "[data-testid='radius-panel']")
      assert choices(view, "radius", "radius") == ~w(sharp soft round)

      assert has_element?(
               view,
               option_button("radius", "radius", "soft") <> "[aria-pressed='true']"
             )
    end

    test "a radius saved in the panel sets the booking page's radius roles",
         %{conn: conn, profile: profile} do
      {page, _dark} = booking_page_vars(profile)
      assert {page["--radius-control"], page["--radius-card"]} == {"8px", "12px"}

      {:ok, view, _html} = customise(conn)
      view |> element(option_button("radius", "radius", "round")) |> render_click()

      assert saved(profile)["radius"] == "round"

      {page, _dark} = booking_page_vars(profile)
      assert {page["--radius-control"], page["--radius-card"]} == {"999px", "20px"}
    end
  end

  describe "density" do
    test "its panel offers comfortable and compact, the default pressed", %{conn: conn} do
      {:ok, view, _html} = customise(conn)

      assert has_element?(view, "[data-testid='density-panel']")
      assert choices(view, "density", "density") == ~w(comfortable compact)

      assert has_element?(
               view,
               option_button("density", "density", "comfortable") <> "[aria-pressed='true']"
             )
    end

    test "a density saved in the panel sets the booking page's density factor",
         %{conn: conn, profile: profile} do
      {page, _dark} = booking_page_vars(profile)
      assert page["--density"] == "1"

      {:ok, view, _html} = customise(conn)
      view |> element(option_button("density", "density", "compact")) |> render_click()

      assert saved(profile)["density"] == "compact"

      {page, dark} = booking_page_vars(profile)
      assert page["--density"] == "0.75"
      refute Map.has_key?(dark, "--density")
    end
  end

  describe "every group together" do
    # Complete and decodable: a stored image is re-encoded, so magic bytes
    # alone are refused.
    @png MediaFixtures.png()

    setup do
      UploadRoot.isolate("tymeslot_showcase")
      :ok
    end

    test "choices made in every panel reach one booking page as its tokens and media",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = customise(conn)

      for {option, field, choice} <- [
            {"colour_mode", "mode", "dark"},
            {"accent", "preset", "rose"},
            {"font", "font", "editorial"},
            {"radius", "radius", "round"},
            {"density", "density", "compact"},
            {"cover", "cover_value", "ocean-sunset"}
          ] do
        view |> element(option_button(option, field, choice)) |> render_click()
      end

      view
      |> file_input("#theme-logo-form", :logo_path, [
        %{
          last_modified: System.system_time(:millisecond),
          name: "logo.png",
          content: @png,
          type: "image/png"
        }
      ])
      |> render_upload("logo.png")

      assert_push_event(view, "upload-complete", %{})

      logo_path = saved(profile)["logo_path"]
      assert logo_path =~ ~r{^themes/#{profile.id}/97/images/}

      {:ok, _page, html} = live(build_conn(), "/#{profile.username}")
      css = theme_css(html)
      page = vars(css)

      refute css =~ "prefers-color-scheme"
      assert page["--theme-color-scheme"] == "dark"
      assert page["--theme-canvas"] == "#0e0e10"
      assert page["--theme-surface"] == "#18181b"
      assert page["--theme-primary"] == "#e8496c"
      assert page["--theme-font-family"] == "var(--font-stack-editorial)"
      assert page["--theme-font-heading"] == "var(--font-heading-editorial)"
      assert {page["--radius-control"], page["--radius-card"]} == {"999px", "20px"}
      assert page["--density"] == "0.75"

      doc = Floki.parse_document!(html)

      assert Floki.attribute(doc, "[data-testid='theme-logo']", "src") == [
               "/uploads/" <> logo_path
             ]

      assert Floki.attribute(doc, "[data-testid='theme-cover']", "src") ==
               [Presets.find_preset_by_id(:cover, "ocean-sunset").src]
    end
  end
end
