defmodule TymeslotWeb.Themes.Shared.Components.TimezonePickerTest do
  @moduledoc """
  The booking page's timezone picker, shared by every theme. The accessibility
  contract the booking-page audit fixed (a trigger named by its visible text
  and announcing a dialog, a named search box) is pinned here once; the
  per-theme booking-page run in `BookingAccessibilityTest` checks the same
  contract end to end.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]
  import TymeslotWeb.AccessibilityAssertions

  alias TymeslotWeb.Themes.Shared.Components.TimezonePicker

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp render_picker(open, search \\ "") do
    assigns = %{open: open, search: search}

    html =
      render_component(
        fn assigns ->
          ~H"""
          <TimezonePicker.timezone_picker open={@open} search={@search} target={nil}>
            <:trigger><span class="probe-trigger">Berlin</span></:trigger>
          </TimezonePicker.timezone_picker>
          """
        end,
        assigns
      )

    Floki.parse_document!(html)
  end

  describe "trigger" do
    test "is named by its visible text, after the screen-reader prefix" do
      assert_named_by_visible_text(render_picker(false), "button.tz-picker__trigger", [
        "Your timezone",
        "Berlin"
      ])
    end

    test "announces the dialog it opens" do
      assert_announces_dialog(render_picker(false), "button.tz-picker__trigger")
    end

    test "toggles the dropdown through the step component" do
      assert Floki.attribute(render_picker(false), "button.tz-picker__trigger", "phx-click") ==
               ["toggle_timezone_dropdown"]
    end
  end

  describe "panel" do
    test "is absent while closed" do
      assert Floki.find(render_picker(false), ".tz-picker__panel") == []
    end

    test "is a labelled dialog with a named search box when open" do
      doc = render_picker(true, "Berlin")

      assert Floki.attribute(doc, ".tz-picker__panel", "role") == ["dialog"]
      assert Floki.attribute(doc, ".tz-picker__panel", "aria-label") == ["Select timezone"]
      assert_input_named(doc, ".tz-picker__search")
      assert Floki.attribute(doc, ".tz-picker__search", "value") == ["Berlin"]
      assert Floki.attribute(doc, ".tz-picker__search", "phx-keyup") == ["search_timezone"]
    end

    test "offers the matching timezones, each with its flag, choosing through the step" do
      doc = render_picker(true, "Berlin")

      assert "Europe/Berlin" in Floki.attribute(
               doc,
               "button.tz-picker__option",
               "phx-value-timezone"
             )

      assert doc |> Floki.attribute("button.tz-picker__option", "phx-click") |> Enum.uniq() ==
               ["change_timezone"]

      berlin = Floki.find(doc, "button.tz-picker__option[phx-value-timezone='Europe/Berlin']")
      assert Floki.find(berlin, ".tz-picker__option-flag") != []
    end
  end
end
