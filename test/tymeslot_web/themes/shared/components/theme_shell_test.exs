defmodule TymeslotWeb.Themes.Shared.Components.ThemeShellTest do
  @moduledoc """
  What every booking page carries, whatever its layout: the theme's outermost
  element marked as the booker root, the organiser's colours, the
  owner-preview disclosure, the language switcher and the configured theme
  extensions. Where the chrome and the extensions sit is the theme's choice;
  the page below lays them out as Quill and Rhythm do, in a grid of its own.
  """
  # Mutates the node-wide :theme_extensions setting.
  use ExUnit.Case, async: false

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Shared.Components.ThemeShell

  defmodule ExtensionProbe do
    use Phoenix.Component

    @spec probe(map()) :: Phoenix.LiveView.Rendered.t()
    def probe(assigns) do
      ~H"""
      <div
        id="extension-probe"
        data-user={@organizer_user_id}
        data-branding={to_string(@should_show_branding)}
        data-theme={@theme_id}
        data-demo={inspect(Map.fetch(assigns, :demo_mode))}
      >
      </div>
      """
    end
  end

  setup do
    ConfigTestHelpers.setup_config(:tymeslot, :theme_extensions, [{ExtensionProbe, :probe}])
  end

  defp render_page(overrides) do
    {demo, overrides} = Keyword.pop(overrides, :demo_mode, :unset)

    assigns =
      Map.merge(
        %{
          theme_tokens: nil,
          locale: "en",
          language_dropdown_open: false,
          show_language_switcher: true,
          owner_preview: false,
          demo_attrs: if(demo == :unset, do: %{}, else: %{demo_mode: demo})
        },
        Map.new(overrides)
      )

    fn assigns ->
      ~H"""
      <ThemeShell.theme_shell class="probe-wrapper" locale={@locale} theme_tokens={@theme_tokens}>
        <:background>
          <div id="probe-background"></div>
        </:background>
        <div class="probe-grid">
          <div class="probe-content">
            <ThemeShell.chrome
              language_class="probe-lang"
              locale={@locale}
              language_dropdown_open={@language_dropdown_open}
              show_language_switcher={@show_language_switcher}
              owner_preview={@owner_preview}
            />
            <p id="probe-step">step</p>
          </div>
          <ThemeShell.extensions
            theme_id="7"
            organizer_user_id={42}
            should_show_branding={true}
            {@demo_attrs}
          />
        </div>
      </ThemeShell.theme_shell>
      """
    end
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  describe "theme_shell/1" do
    test "marks the theme's outermost element, and only it, as the booker root" do
      doc = render_page([])

      assert [{"div", attrs, _children}] = Floki.find(doc, "[data-booker-root]")
      assert {"class", "probe-wrapper"} in attrs
      assert {"data-locale", "en"} in attrs
    end

    test "writes the organiser's customisation onto :root, and nothing without it" do
      styled = render_page(theme_tokens: %Tokens{vars: %{"--theme-primary" => "#123456"}})

      assert styled |> Floki.find("[data-booker-root] > style") |> Floki.raw_html() =~
               ~r/:root:root\s*\{\s*--theme-primary: #123456;/

      assert Floki.find(render_page(theme_tokens: nil), "style") == []
      assert Floki.find(render_page(theme_tokens: %Tokens{}), "style") == []
    end

    test "renders the background first, then the theme's own markup, inside the root" do
      children =
        []
        |> render_page()
        |> Floki.find("[data-booker-root] > *")
        |> Enum.map(fn {tag, attrs, _children} ->
          attrs = Map.new(attrs)
          {tag, attrs["id"] || attrs["class"]}
        end)

      assert children == [{"div", "probe-background"}, {"div", "probe-grid"}]
    end
  end

  describe "chrome/1" do
    test "shows the owner-preview notice only in owner preview, where the theme puts it" do
      assert Floki.find(
               render_page(owner_preview: true),
               ".probe-content > [data-testid=preview-notice]"
             ) != []

      assert Floki.find(render_page(owner_preview: false), "[data-testid=preview-notice]") == []
    end

    test "shows the language switcher only where the page decided to" do
      assert Floki.find(render_page(show_language_switcher: true), ".probe-lang.visible") != []
      assert Floki.find(render_page(show_language_switcher: false), ".probe-lang.hidden") != []

      # A theme hides the container through the semantic class, never by
      # styling the Tailwind utility name.
      assert Floki.find(
               render_page(show_language_switcher: false),
               ".probe-lang.theme-shell__language--hidden"
             ) != []

      assert Floki.find(render_page(language_dropdown_open: nil), ".probe-lang") == []
      assert Floki.find(render_page(locale: nil), ".probe-lang") == []
    end
  end

  describe "extensions/1" do
    test "hands the branding inputs to the theme extensions, where the theme puts them" do
      doc = render_page([])

      assert Floki.attribute(doc, ".probe-grid > #extension-probe", "data-user") == ["42"]
      assert Floki.attribute(doc, ".probe-grid > #extension-probe", "data-branding") == ["true"]
    end

    test "hands the theme id to the theme extensions" do
      assert Floki.attribute(render_page([]), "#extension-probe", "data-theme") == ["7"]
    end

    test "hands demo mode to the theme extensions only when the page assigned it" do
      assert Floki.attribute(render_page(demo_mode: true), "#extension-probe", "data-demo") ==
               ["{:ok, true}"]

      assert Floki.attribute(render_page([]), "#extension-probe", "data-demo") == [":error"]
    end
  end

  describe "style_attrs/1" do
    test "gives no style attribute without a style, and the style as given otherwise" do
      assert ThemeShell.style_attrs(nil) == []
      assert ThemeShell.style_attrs("background: black") == [style: "background: black"]
      assert ThemeShell.style_attrs("") == [style: ""]
    end
  end
end
