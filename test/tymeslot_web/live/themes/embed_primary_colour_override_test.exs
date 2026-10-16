defmodule TymeslotWeb.Live.Themes.EmbedPrimaryColourOverrideTest do
  @moduledoc """
  An embed's `data-primary-color` repaints the booking page it frames, in every
  theme, without a browser.

  `embed.js` turns the attribute into `?primary-color=` on the iframe URL
  (`?embed=1&primary-color=%23rrggbb`, pinned in
  `assets/js/__tests__/embed.test.js`); `Context.from_params/2` casts it into
  the context's overrides and the theme's spec rebuilds the palette around it.
  `TymeslotWeb.E2E.EmbedPrimaryColourTest` proves the same in a real browser,
  but no CI job runs `:e2e`, so this is the coverage that runs.

  Assertions read the theme's own `<style>` block (the `:root:root` one
  `ThemeStyle` writes), not the whole page, so a colour that only turns up
  somewhere else in the markup cannot satisfy them. A theme that follows the
  visitor's OS writes its dark set in a second block after it; the root block
  is the page as a light-mode visitor sees it, which is what is compared.
  """
  use TymeslotWeb.ConnCase, async: false

  @moduletag :themes
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  @embedder "embedder.test"

  # Clears 4.5:1 as text on every light card a shipped theme has, so a theme
  # that fits its accent to the card keeps it exactly as given.
  @override "#e11d48"

  setup tags do
    Mox.set_mox_from_context(tags)
    TestMocks.setup_calendar_mocks()

    user = insert(:user)
    insert(:calendar_integration, user: user, is_active: true)
    insert(:meeting_type, user: user, name: "Quick Chat", duration_minutes: 30)

    %{user: user}
  end

  defp embeddable_profile(user, theme_id) do
    insert(:profile,
      user: user,
      username: "embed-colour-#{System.unique_integer([:positive])}",
      booking_theme: theme_id,
      allowed_embed_domains: [@embedder]
    )
  end

  # Loads the page as the embed iframe does, and returns its theme `<style>`
  # block twice: from the static render (the first paint) and from the
  # connected LiveView.
  defp embedded_css(conn, profile, params) do
    path = "/#{profile.username}?" <> URI.encode_query([{"embed", "1"} | params])
    conn = put_req_header(conn, "referer", "https://#{@embedder}/page")

    static_html = conn |> get(path) |> html_response(200)
    {:ok, view, _html} = live(conn, path)

    assert :sys.get_state(view.pid).socket.assigns[:embedded] == true,
           "the page was not mounted as an embed, so this proves nothing about one"

    {theme_css(static_html), theme_css(render(view))}
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

  # The root block's declarations: everything before the first closing brace.
  defp vars(css) do
    [_before, root] = String.split(css, ":root:root {", parts: 2)
    [block | _rest] = String.split(root, "}", parts: 2)

    ~r/(--[a-z0-9-]+):\s*([^;]+);/
    |> Regex.scan(block, capture: :all_but_first)
    |> Map.new(fn [name, value] -> {name, value} end)
  end

  for theme <- ThemeTestMatrix.all() do
    describe "#{theme.name}" do
      test "a valid ?primary-color= sets the primary, its hover shade and its contrast pair",
           %{conn: conn, user: user} do
        profile = embeddable_profile(user, unquote(theme.id))

        {default_static, _default_live} = embedded_css(conn, profile, [])
        {static_css, live_css} = embedded_css(conn, profile, [{"primary-color", @override}])

        default = vars(default_static)
        overridden = vars(static_css)

        # Anchored: the theme's default is something else, or the override
        # could pass without doing anything.
        refute default["--theme-primary"] == @override

        assert overridden["--theme-primary"] == @override

        # The contrast pair is recomputed for the new colour: the ink on it,
        # and the filled-control surface nudged to meet contrast against that
        # ink. The hover shade is derived from it too.
        for token <- ~w(--theme-primary-hover --theme-on-primary --theme-primary-solid
                        --theme-primary-solid-hover) do
          assert overridden[token] =~ ~r/\A#[0-9a-f]{6}\z/i, "#{token} missing or not a colour"
        end

        for token <- ~w(--theme-primary-hover --theme-primary-solid --theme-primary-solid-hover) do
          refute overridden[token] == default[token], "#{token} kept the palette's value"
        end

        refute overridden["--theme-primary-hover"] == @override

        # The connected LiveView keeps the override the first paint had.
        assert vars(live_css)["--theme-primary"] == @override
      end

      for bad <- ["red;}body{", "#12", "#ff0000;}body{display:none"] do
        test "an invalid ?primary-color= (#{inspect(bad)}) leaves the theme's default and writes nothing unsafe",
             %{conn: conn, user: user} do
          profile = embeddable_profile(user, unquote(theme.id))

          {default_css, _live} = embedded_css(conn, profile, [])
          {static_css, live_css} = embedded_css(conn, profile, [{"primary-color", unquote(bad)}])

          # Exactly the theme's own style, block for block: nothing was
          # added, and nothing closed a block early.
          for css <- [static_css, live_css] do
            assert css == default_css
            refute css =~ "body"
            refute css =~ "red"
          end
        end
      end
    end
  end
end
