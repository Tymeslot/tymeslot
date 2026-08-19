defmodule TymeslotWeb.Components.UIExtendedTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  import Phoenix.Component

  alias TymeslotWeb.Components.CoreComponents.Navigation
  alias TymeslotWeb.Components.Shared.TimeOptions
  alias TymeslotWeb.Shared.Auth.IconComponents

  describe "TimeOptions" do
    test "time_options/0 returns 24h interval pairs" do
      options = TimeOptions.time_options()
      assert length(options) == 24 * 4
      assert {"00:00", "00:00"} = hd(options)
      assert {"23:45", "23:45"} = List.last(options)
    end
  end

  describe "CoreComponents.Navigation" do
    test "detail_row/1 renders correctly" do
      assigns = %{label: "Test Label", value: "Test Value"}
      html = render_component(&Navigation.detail_row/1, assigns)
      assert html =~ "Test Label"
      assert html =~ "Test Value"
    end

    test "back_link/1 renders correctly" do
      assigns = %{to: "/test"}

      html =
        render_component(
          fn assigns ->
            ~H"""
            <Navigation.back_link to={@to}>Back</Navigation.back_link>
            """
          end,
          assigns
        )

      assert html =~ "/test"
      assert html =~ "Back"
    end
  end

  describe "Auth.IconComponents" do
    # "renders an <svg>" is true of every heroicon, so each function's own
    # glyph path and colour are pinned: swapping two of these components, or
    # letting a renamed icon fall through to the unknown-icon branch, has to
    # fail here.
    test "email_icon renders the solid mini envelope in the input adornment colour" do
      html = render_component(&IconComponents.email_icon/1, %{})

      assert html =~ ~s(viewBox="0 0 20 20")
      assert html =~ ~s(fill="currentColor")

      assert html =~
               "M3 4a2 2 0 0 0-2 2v1.161l8.441 4.221a1.25 1.25 0 0 0 1.118 0L19 7.162V6a2 2 0 0 0-2-2H3Z"

      assert html =~ "text-tymeslot-400"
    end

    test "success_icon renders the outline check-circle in green" do
      html = render_component(&IconComponents.success_icon/1, %{})

      assert html =~ ~s(viewBox="0 0 24 24")
      assert html =~ "M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
      assert html =~ "text-green-500"
    end

    test "email_verification_icon renders the outline envelope in the hero colour" do
      html = render_component(&IconComponents.email_verification_icon/1, %{})

      assert html =~ ~s(viewBox="0 0 24 24")

      assert html =~
               "M21.75 6.75v10.5a2.25 2.25 0 0 1-2.25 2.25h-15a2.25 2.25 0 0 1-2.25-2.25V6.75"

      assert html =~ "text-turquoise-50"
    end
  end
end
