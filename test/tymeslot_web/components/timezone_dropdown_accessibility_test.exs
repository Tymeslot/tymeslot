defmodule TymeslotWeb.Components.TimezoneDropdownAccessibilityTest do
  @moduledoc """
  Accessibility contract for the shared timezone dropdown used by onboarding
  and profile settings.

  The booking page carried the same three defects in its own copies of this
  control, and they are pinned there by
  `TymeslotWeb.Live.Scheduling.BookingAccessibilityTest`. This module covers the
  dashboard-side component, which is a separate implementation and can regress
  independently.
  """

  use TymeslotWeb.ConnCase, async: true

  @moduletag :profiles
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest

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
      doc = render_dropdown(false)

      [trigger] = Floki.find(doc, "button[aria-haspopup]")

      # WCAG 2.5.3 Label in Name: an aria-label of "Select timezone" replaced
      # the visible timezone, leaving speech-input users unable to activate the
      # control by what they can see.
      assert Floki.attribute([trigger], "aria-label") == []

      name = trigger |> Floki.text() |> String.replace(~r/\s+/, " ")
      assert name =~ "Your Timezone"
      assert name =~ "Berlin"
    end

    test "it announces the dialog it opens, not a menu" do
      doc = render_dropdown(false)

      assert Floki.attribute(doc, "button[aria-haspopup]", "aria-haspopup") == ["dialog"]
    end
  end

  describe "search box" do
    test "it has an accessible name" do
      doc = render_dropdown(true)

      inputs = Floki.find(doc, "#timezone-search")

      # Anchored: an empty list would pass the check below vacuously.
      assert length(inputs) == 1

      # A placeholder is not an accessible name: it disappears on input and
      # several screen readers never announce it.
      assert [label] = Floki.attribute(inputs, "aria-label")
      assert label != ""
    end
  end

  describe "labels" do
    test "no label element is bound to nothing" do
      doc = render_dropdown(true)

      orphans =
        doc
        |> Floki.find("label")
        |> Enum.reject(fn label ->
          Floki.attribute([label], "for") != [] or
            Floki.find([label], "input, select, textarea") != []
        end)

      assert orphans == []
    end
  end
end
