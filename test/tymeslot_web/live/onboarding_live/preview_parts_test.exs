defmodule TymeslotWeb.OnboardingLive.PreviewPartsTest do
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.ThemeTestMatrix

  defmodule Bare do
    @moduledoc false
    # A theme module that draws no onboarding preview of its own.
  end

  @sample_slots [%{label: "9:00", state: :default, check: false}]

  describe "theme_preview/1" do
    for theme_id <- ThemeTestMatrix.ids() do
      test "theme #{theme_id} draws a thumbnail tinted with the primary colour" do
        html =
          render_component(&PreviewParts.theme_preview/1,
            theme_module: ThemeInfo.get_theme_module(unquote(theme_id)),
            variant: :thumbnail,
            primary: "#123456"
          )

        assert html =~ "#123456"
      end

      test "theme #{theme_id} draws a card around the shared header" do
        assigns = %{module: ThemeInfo.get_theme_module(unquote(theme_id)), slots: @sample_slots}

        html =
          rendered_to_string(~H"""
          <PreviewParts.theme_preview theme_module={@module} variant={:card} colors={%{}} slots={@slots}>
            <:header>
              <p id="shared-header">Ada Lovelace</p>
            </:header>
          </PreviewParts.theme_preview>
          """)

        assert html =~ ~s(id="shared-header")
        assert html =~ "9:00"
        assert html =~ "Book"
      end
    end

    test "falls back to the generic mock for a module without onboarding_preview/1" do
      assigns = %{slots: @sample_slots}

      html =
        rendered_to_string(~H"""
        <PreviewParts.theme_preview theme_module={Bare} variant={:card} colors={%{}} slots={@slots}>
          <:header>
            <p id="shared-header">Ada Lovelace</p>
          </:header>
        </PreviewParts.theme_preview>
        """)

      assert html =~ ~s(id="shared-header")
      assert html =~ "9:00"
      assert html =~ "Book"
    end
  end

  describe "each theme keeps its own shape" do
    test "Quill's card has the month calendar grid and Rhythm's does not" do
      assigns = %{slots: @sample_slots}

      quill =
        rendered_to_string(~H"""
        <PreviewParts.theme_preview
          theme_module={TymeslotWeb.Themes.Quill.Theme}
          variant={:card}
          colors={%{}}
          slots={@slots}
        >
          <:header></:header>
        </PreviewParts.theme_preview>
        """)

      rhythm =
        rendered_to_string(~H"""
        <PreviewParts.theme_preview
          theme_module={TymeslotWeb.Themes.Rhythm.Theme}
          variant={:card}
          colors={%{}}
          slots={@slots}
        >
          <:header></:header>
        </PreviewParts.theme_preview>
        """)

      assert quill =~ "grid-cols-7"
      refute rhythm =~ "grid-cols-7"
    end
  end

  describe "colors/1" do
    test "reads the previews' colours from resolved tokens, leaving out what the theme lacks" do
      tokens = %Tokens{
        vars: %{
          "--theme-primary" => "#111111",
          "--theme-canvas" => "#222222",
          "--theme-background" => "var(--theme-canvas)"
        }
      }

      assert PreviewParts.colors(tokens) == %{primary: "#111111", background: "#222222"}
    end
  end
end
