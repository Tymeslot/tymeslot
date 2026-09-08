defmodule TymeslotWeb.AccessibilityAssertionsTest do
  @moduledoc """
  Covers `accessible_name/2`, the name-resolution helper the accessibility
  contracts are built on.

  It is worth its own tests because every "the control is named by what you can
  see" assertion in the suite trusts it: if it resolves a name the wrong way,
  the contracts above it report on something other than what a screen reader
  would announce, in either direction.
  """

  use ExUnit.Case, async: true

  @moduletag :ui
  @moduletag :unit

  import TymeslotWeb.AccessibilityAssertions

  defp parse(html), do: Floki.parse_document!(html)

  defp name(html, selector) do
    doc = parse(html)
    [element] = Floki.find(doc, selector)
    accessible_name(doc, element)
  end

  describe "accessible_name/2" do
    test "falls back to the element's own text" do
      assert name(~s(<button id="b">Book a meeting</button>), "#b") == "Book a meeting"
    end

    test "collapses the whitespace HEEx leaves between nested elements" do
      html =
        ~s(<button id="b">\n  <svg></svg>\n  Your timezone\n  <span>New York</span>\n</button>)

      assert name(html, "#b") == "Your timezone New York"
    end

    test "an aria-label wins over the visible text" do
      html = ~s(<button id="b" aria-label="Select timezone">Your timezone</button>)

      assert name(html, "#b") == "Select timezone"
    end

    test "an aria-labelledby wins over both" do
      html = """
      <span id="heading">Your timezone</span>
      <button id="b" aria-labelledby="heading" aria-label="Select timezone">New York</button>
      """

      assert name(html, "#b") == "Your timezone"
    end

    test "aria-labelledby joins every id it lists, in order" do
      html = """
      <span id="heading">Your timezone</span>
      <span id="value">New York</span>
      <button id="b" aria-labelledby="heading value">ignored</button>
      """

      assert name(html, "#b") == "Your timezone New York"
    end

    test "an aria-labelledby pointing at nothing resolves to an empty name" do
      # A dangling reference is a real defect, and the name it produces is
      # empty rather than the visible text: browsers do not fall back once the
      # attribute is present. A contract asserting the visible text appears in
      # the name must fail here, not quietly pass on the button's own words.
      html = ~s(<button id="b" aria-labelledby="missing">Your timezone</button>)

      assert name(html, "#b") == ""
    end
  end
end
