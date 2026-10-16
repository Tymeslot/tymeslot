defmodule TymeslotWeb.Themes.Shared.ThemeStyleTest do
  @moduledoc """
  The theme `<style>` block is the one place organiser-controlled values reach
  CSS. Pins its format, the per-value filter, and the `sanitize_css/1`
  backstop behind it.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Shared.ThemeStyle

  defp tokens(vars, dark_vars \\ %{}), do: %Tokens{vars: vars, dark_vars: dark_vars}

  defp render_style(tokens) do
    assigns = %{tokens: tokens}
    rendered_to_string(~H"<ThemeStyle.theme_style tokens={@tokens} />")
  end

  describe "css/1" do
    test "writes the vars into one :root:root block, sorted" do
      assert ThemeStyle.css(
               tokens(%{"--theme-primary" => "#06b6d4", "--theme-canvas" => "#0f172a"})
             ) ==
               ":root:root { --theme-canvas: #0f172a; --theme-primary: #06b6d4; }"
    end

    test "writes dark_vars into a prefers-color-scheme block" do
      css =
        ThemeStyle.css(tokens(%{"--theme-canvas" => "#0f172a"}, %{"--theme-canvas" => "#ffffff"}))

      assert css =~ ":root:root { --theme-canvas: #0f172a; }"

      assert css =~
               "@media (prefers-color-scheme: dark) { :root:root { --theme-canvas: #ffffff; } }"
    end

    test "a light root comes first and its dark counterpart after it, so the dark set wins while the OS is dark" do
      # Same selector, so source order decides.
      assert ThemeStyle.css(
               tokens(%{"--theme-canvas" => "#faf7f2"}, %{"--theme-canvas" => "#1b1a24"})
             ) ==
               ":root:root { --theme-canvas: #faf7f2; }\n" <>
                 "@media (prefers-color-scheme: dark) { :root:root { --theme-canvas: #1b1a24; } }"
    end

    test "accepts the value shapes the palettes and presets use" do
      vars = %{
        "--theme-surface" => "rgba(30, 41, 59, 0.5)",
        "--theme-background" => "linear-gradient(135deg, #0f0c29 0%, #302b63 50%, #24243e 100%)",
        "--theme-link" => "var(--theme-canvas)"
      }

      css = ThemeStyle.css(tokens(vars))

      for {name, value} <- vars, do: assert(css =~ "#{name}: #{value};")
    end

    test "drops a value that tries to close the style element, keeping the rest" do
      vars = %{
        "--theme-primary" => "red</style><script>alert(1)</script>",
        "--theme-canvas" => "#0f172a"
      }

      assert ThemeStyle.css(tokens(vars)) == ":root:root { --theme-canvas: #0f172a; }"
    end

    test "drops a value that tries to end the declaration or the block" do
      vars = %{"--theme-primary" => "#fff;}body{display:none", "--theme-canvas" => "#0f172a"}

      assert ThemeStyle.css(tokens(vars)) == ":root:root { --theme-canvas: #0f172a; }"
    end

    test "drops values carrying quotes or escapes" do
      vars = %{
        "--theme-a" => "url('x')",
        "--theme-b" => "\\3c/style\\3e",
        "--theme-canvas" => "#0f172a"
      }

      assert ThemeStyle.css(tokens(vars)) == ":root:root { --theme-canvas: #0f172a; }"
    end

    test "drops names that are not plain custom properties" do
      vars = %{"color" => "red", "--x;}body{" => "red", "--theme-canvas" => "#0f172a"}

      assert ThemeStyle.css(tokens(vars)) == ":root:root { --theme-canvas: #0f172a; }"
    end

    test "sanitize_css/1 still blanks a block the per-value filter lets through" do
      # `expression(` uses only characters a gradient needs, so only the
      # backstop can catch it.
      vars = %{"--theme-primary" => "expression(alert(1))", "--theme-canvas" => "#0f172a"}

      assert ThemeStyle.css(tokens(vars)) == ""
    end

    test "nil and empty tokens produce nothing" do
      assert ThemeStyle.css(nil) == ""
      assert ThemeStyle.css(tokens(%{})) == ""
    end
  end

  describe "theme_style/1" do
    test "renders one style element" do
      html = render_style(tokens(%{"--theme-canvas" => "#0f172a"}))

      assert html =~ ~s(<style type="text/css">:root:root { --theme-canvas: #0f172a; }</style>)
    end

    test "renders nothing without tokens" do
      refute render_style(nil) =~ "<style"
      refute render_style(tokens(%{})) =~ "<style"
    end
  end

  describe "inline_background/1" do
    test "gradient, colour and image become the inline style the wrappers used to build" do
      assert ThemeStyle.inline_background(%{kind: :gradient, css: "linear-gradient(red, blue)"}) ==
               "background: linear-gradient(red, blue);"

      assert ThemeStyle.inline_background(%{kind: :color, color: "#123456"}) ==
               "background-color: #123456;"

      assert ThemeStyle.inline_background(%{
               kind: :image,
               url: "/images/themes/backgrounds/a.webp"
             }) ==
               "background-image: url('/images/themes/backgrounds/a.webp'); background-size: cover; " <>
                 "background-position: center; background-repeat: no-repeat;"
    end

    test "video and nil have no inline style" do
      assert ThemeStyle.inline_background(%{kind: :video, sources: [], poster: nil}) == nil
      assert ThemeStyle.inline_background(nil) == nil
    end
  end
end
