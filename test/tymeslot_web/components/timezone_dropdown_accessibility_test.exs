defmodule TymeslotWeb.Components.TimezoneDropdownAccessibilityTest do
  @moduledoc """
  Accessibility contract for the shared timezone dropdown used by onboarding
  and profile settings.

  The booking page carried the same defects in its own copies of this control,
  and they are pinned there by
  `TymeslotWeb.Live.Scheduling.BookingAccessibilityTest`. This module covers the
  dashboard-side component, which is a separate implementation and can regress
  independently; the assertions themselves are shared between the two, in
  `TymeslotWeb.AccessibilityAssertions`.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :profiles
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import TymeslotWeb.AccessibilityAssertions

  alias TymeslotWeb.Components.TimezoneDropdown

  defp render_dropdown(open) do
    assigns = %{open: open}

    html =
      render_component(
        fn assigns ->
          ~H"""
          <TimezoneDropdown.timezone_dropdown
            profile={%{timezone: "Europe/Berlin"}}
            timezone_dropdown_open={@open}
            timezone_search=""
          />
          """
        end,
        assigns
      )

    Floki.parse_document!(html)
  end

  describe "trigger" do
    test "its accessible name contains its visible text" do
      assert_named_by_visible_text(render_dropdown(false), "button[aria-haspopup]", [
        "Your Timezone",
        "Berlin"
      ])
    end

    test "it announces the dialog it opens, not a menu" do
      assert_announces_dialog(render_dropdown(false), "button[aria-haspopup]")
    end
  end

  describe "search box" do
    test "it has an accessible name" do
      assert_input_named(render_dropdown(true), "#timezone-search")
    end
  end

  describe "labels" do
    # The orphan-label sweep the booking page runs cannot apply here: this
    # component renders no `<label>` at all, and an "are any labels orphaned"
    # check over an empty list passes however the component breaks.
    #
    # What is worth pinning is the decision that produced that emptiness. The
    # visible "Your Timezone" heading names no control — the trigger below it
    # carries its own accessible name — so it is a styled `<div>`. As a
    # `<label>` it would be exactly the orphan the audit reported.
    test "the visual heading is not a label element" do
      doc = render_dropdown(true)

      assert Floki.find(doc, "label") == []

      assert doc |> Floki.find("div.label") |> Floki.text() =~ "Your Timezone"
    end
  end
end
