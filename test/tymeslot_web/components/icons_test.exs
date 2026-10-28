defmodule TymeslotWeb.Components.IconsTest do
  @moduledoc """
  Guards the icon pipeline (priv SVGs → compile-time maps → inline `<svg>`):
  the vendored Heroicons, Core's custom icons in priv/icons, and the `<.icon>`
  renderer they share. Regression cover for the failure mode that motivated
  vendoring: an empty or partially-populated icon map silently rendering blank
  tiles.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :ui

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.CustomIcons
  alias TymeslotWeb.Components.CoreComponents.Heroicons
  alias TymeslotWeb.Components.CoreComponents.Icons

  # One representative name proves each of the four vendored style directories
  # (24/outline, 24/solid, 20/solid, 16/solid) loaded — a whole style going
  # missing slips past the compile-time empty-map guard, so assert it here.
  describe "Heroicons.fetch/1 — all four styles vendored" do
    for {suffix, label} <- [
          {"", "outline (24)"},
          {"-solid", "solid (24)"},
          {"-mini", "mini (20)"},
          {"-micro", "micro (16)"}
        ] do
      test "resolves the #{label} style" do
        name = "hero-academic-cap" <> unquote(suffix)

        assert Heroicons.known?(name)
        assert {:ok, %{body: body, attrs: attrs}} = Heroicons.fetch(name)
        assert byte_size(body) > 0
        assert {"viewBox", view_box} = List.keyfind(attrs, "viewBox", 0)
        assert view_box =~ ~r/^[\d.\s]+$/
      end
    end

    test "a spread of commonly-used icons all resolve (guards partial vendoring)" do
      for name <- ~w(hero-calendar-days hero-x-mark hero-check hero-arrow-path
                     hero-user hero-cog-6-tooth hero-trash hero-pencil) do
        assert Heroicons.known?(name), "expected #{name} to be vendored"
      end
    end

    test "an unknown name returns :error rather than raising" do
      refute Heroicons.known?("hero-definitely-not-a-real-icon")
      assert :error = Heroicons.fetch("hero-definitely-not-a-real-icon")
    end
  end

  describe "icon/1 component rendering" do
    test "renders an inline <svg> with path markup for an outline icon" do
      html = render_icon(%{name: "hero-academic-cap"})

      assert html =~ "<svg"
      assert html =~ ~s(stroke="currentColor")
      assert html =~ "<path"
    end

    test "renders a filled <svg> for a solid icon" do
      html = render_icon(%{name: "hero-academic-cap-solid"})

      assert html =~ "<svg"
      assert html =~ ~s(fill="currentColor")
    end

    test "passes through size and colour classes" do
      html = render_icon(%{name: "hero-calendar-days", class: "w-5 h-5 text-rose-500"})

      assert html =~ "w-5 h-5 text-rose-500"
    end

    test "an unknown hero-* name degrades to an empty span, not a crash or leaked name" do
      html = render_icon(%{name: "hero-definitely-not-a-real-icon"})

      assert html =~ "<span"
      refute html =~ "<svg"
      refute html =~ "definitely-not-a-real-icon"
    end

    test "keeps the heroicon's own stroke weight, which a class can override" do
      html = render_icon(%{name: "hero-check", class: "stroke-3"})

      assert html =~ ~s(stroke-width="1.5")
      assert html =~ "stroke-3"
    end

    test "passes global attributes through to the svg" do
      html = render_icon(%{name: "hero-eye", rest: %{"data-eye-open": true, id: "eye"}})

      assert html =~ ~s(data-eye-open)
      assert html =~ ~s(id="eye")
      assert html =~ ~s(aria-hidden="true")
    end
  end

  describe "custom icons from priv/icons" do
    test "every file in priv/icons is drawable by its file name" do
      dir = Path.expand("../../../priv/icons", __DIR__)
      names = dir |> File.ls!() |> Enum.map(&Path.basename(&1, ".svg")) |> Enum.sort()

      assert names != []
      assert Enum.sort(CustomIcons.names()) == names
      for name <- names, do: assert(Icons.known?(name), "expected #{name} to be drawable")
    end

    test "renders a brand mark filled in currentColor at the default 24px" do
      html = render_icon(%{name: "brand-slack", class: "w-6 h-6"})

      assert html =~ "<svg"
      assert html =~ ~s(fill="currentColor")
      assert html =~ ~s(width="24")
      assert html =~ "w-6 h-6"
    end

    test "an unknown name degrades to an empty span without leaking the name" do
      html = render_icon(%{name: "brand-not-a-real-mark"})

      assert html =~ "<span"
      refute html =~ "<svg"
      refute html =~ "brand-not-a-real-mark"
      refute Icons.known?("brand-not-a-real-mark")
    end
  end

  defp render_icon(assigns) do
    assigns = Map.merge(%{class: nil, style: nil, rest: %{}}, assigns)
    render_component(&Icons.icon/1, assigns)
  end
end
