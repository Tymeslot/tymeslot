defmodule TymeslotWeb.Themes.Shared.Journey.ComponentsTest do
  @moduledoc """
  The frame the visible moments sit in, which leaves a paged journey's DOM as
  it was, and a moment's heading, which takes the focus only when its moment
  has just become current through the visitor's own action.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TymeslotWeb.Themes.Shared.Journey.Components
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Continuous
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

  defp heading(attrs) do
    assigns = Map.new(attrs)

    html =
      rendered_to_string(~H"""
      <Components.moment_heading moment={@moment} moment_state={@moment_state} focus={@focus}>
        When suits you?
      </Components.moment_heading>
      """)

    Floki.parse_fragment!(html)
  end

  describe "frame/1" do
    test "renders a paged journey's moment bare" do
      assigns = %{navigator: Paged}

      html =
        rendered_to_string(~H"""
        <Components.frame navigator={@navigator}>
          <p id="moment">x</p>
        </Components.frame>
        """)

      assert String.trim(html) == ~s(<p id="moment">x</p>)
    end

    test "wraps the moments in the navigator's frame" do
      assigns = %{navigator: Continuous}

      html =
        rendered_to_string(~H"""
        <Components.frame navigator={@navigator}>
          <p id="moment">x</p>
        </Components.frame>
        """)

      assert [_div] =
               Floki.find(Floki.parse_fragment!(html), "div.journey--continuous > p#moment")
    end
  end

  describe "moment_heading/1" do
    test "takes the focus when its moment has just become current" do
      doc = heading(moment: :when, moment_state: :current, focus: :when)

      assert [mounted] = Floki.attribute(doc, "#when-heading-current", "phx-mounted")
      assert mounted =~ "focus"
      assert Floki.attribute(doc, "#when-heading-current", "tabindex") == ["-1"]
    end

    test "leaves the focus alone on page load and for any other moment" do
      assert Floki.attribute(
               heading(moment: :when, moment_state: :current, focus: nil),
               "h2",
               "phx-mounted"
             ) == []

      assert Floki.attribute(
               heading(moment: :when, moment_state: :current, focus: :you),
               "h2",
               "phx-mounted"
             ) == []
    end

    test "leaves the focus alone once its moment is done" do
      doc = heading(moment: :when, moment_state: :done, focus: :when)

      assert [_heading] = Floki.find(doc, "h2#when-heading-done")
      assert Floki.attribute(doc, "#when-heading-done", "phx-mounted") == []
    end
  end
end
