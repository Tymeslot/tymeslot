defmodule TymeslotWeb.Components.HeroiconsTest do
  @moduledoc """
  Guards the vendored-heroicon pipeline (priv/heroicons → compile-time map →
  inline `<svg>`). Regression cover for the failure mode that motivated
  vendoring: an empty or partially-populated icon map silently rendering blank
  tiles. The same `<.icon>` component serves both Core and SaaS, so these
  assertions also cover SaaS-only icon names — there is no per-app icon subset.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

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
        assert {:ok, %{body: body, view_box: view_box}} = Heroicons.fetch(name)
        assert byte_size(body) > 0
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

    test "a non-heroicon name renders its literal text" do
      html = render_icon(%{name: "custom-marker"})

      assert html =~ "custom-marker"
    end
  end

  defp render_icon(assigns) do
    assigns = Map.merge(%{class: nil, style: nil}, assigns)
    render_component(&Icons.icon/1, assigns)
  end
end
