defmodule TymeslotWeb.Components.CoreComponentsTabBarTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :dashboard

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Navigation

  defp panel_tabs do
    [
      %{id: "details", label: "Details", icon: "hero-pencil-square"},
      %{id: "booking", label: "Booking", error: true},
      %{id: "reminders", label: "Reminders"}
    ]
  end

  defp render_bar(tabs, active, extra \\ %{}) do
    assigns = Map.merge(%{tabs: tabs, active: active, overflow: :scroll}, extra)

    ~H"""
    <Navigation.tab_bar
      id="test-tabs"
      tabs={@tabs}
      active_tab={@active}
      overflow={@overflow}
      aria_label="Test tabs"
    />
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  defp link_tabs do
    [
      %{id: :calendars, label: "Calendars", patch: "/x?tab=calendars", count: 3},
      %{
        id: :video,
        label: "Video",
        patch: "/x?tab=video",
        status: :warning,
        status_label: "Warning - needs attention"
      },
      %{id: :payments, label: "Payments", patch: "/x?tab=payments"}
    ]
  end

  defp attr_of(doc, selector, name), do: Floki.attribute(doc, selector, name)

  describe "panel tabs" do
    test "render a labelled tablist of tab buttons wired to their panels" do
      doc = render_bar(panel_tabs(), "details")

      assert attr_of(doc, "#test-tabs", "role") == ["tablist"]
      assert attr_of(doc, "#test-tabs", "aria-label") == ["Test tabs"]
      assert attr_of(doc, "#test-tabs", "phx-hook") == ["ScrollStrip"]

      assert length(Floki.find(doc, "#test-tabs button[role='tab'][type='button']")) == 3
      assert attr_of(doc, "#test-tabs-tab-booking", "aria-controls") == []
      assert attr_of(doc, "#test-tabs-tab-booking", "phx-click") == ["switch_tab"]
      assert attr_of(doc, "#test-tabs-tab-booking", "phx-value-tab") == ["booking"]
    end

    test "select the active tab, and only it, and give it the only tab stop" do
      doc = render_bar(panel_tabs(), "booking")

      assert attr_of(doc, "#test-tabs-tab-booking", "aria-selected") == ["true"]
      assert attr_of(doc, "#test-tabs-tab-details", "aria-selected") == ["false"]
      assert attr_of(doc, "#test-tabs-tab-reminders", "aria-selected") == ["false"]

      assert attr_of(doc, "#test-tabs-tab-booking", "tabindex") == ["0"]
      assert attr_of(doc, "#test-tabs-tab-details", "tabindex") == ["-1"]
      assert attr_of(doc, "#test-tabs-tab-reminders", "tabindex") == ["-1"]
    end

    # A caller may render only the selected panel, so only the selected tab
    # names one; the others would point at elements that are not there.
    test "name the selected tab's panel, and no other, in aria-controls" do
      doc = render_bar(panel_tabs(), "booking")

      assert attr_of(doc, "#test-tabs-tab-booking", "aria-controls") == [
               "test-tabs-panel-booking"
             ]

      assert attr_of(doc, "#test-tabs-tab-details", "aria-controls") == []
      assert attr_of(doc, "#test-tabs-tab-reminders", "aria-controls") == []
    end

    test "scope tab and panel ids to the strip" do
      assert Navigation.tab_id("strip", "a") == "strip-tab-a"
      assert Navigation.panel_id("strip", :a) == "strip-panel-a"

      doc = render_bar(panel_tabs(), "details")
      assert Floki.find(doc, "#tab-details") == []
      assert [_tab] = Floki.find(doc, "#test-tabs-tab-details")
    end

    test "keep the first tab reachable from the keyboard when none is selected" do
      doc = render_bar(panel_tabs(), nil)

      assert attr_of(doc, "#test-tabs-tab-details", "tabindex") == ["0"]
      assert attr_of(doc, "#test-tabs-tab-booking", "tabindex") == ["-1"]
    end

    test "push the configured event with the tab id" do
      assigns = %{}

      doc =
        ~H"""
        <Navigation.tab_bar
          id="t"
          aria_label="T"
          tabs={[%{id: "a", label: "A"}]}
          active_tab="a"
          event="pick"
        />
        """
        |> rendered_to_string()
        |> Floki.parse_fragment!()

      assert attr_of(doc, "#t-tab-a", "phx-click") == ["pick"]
    end

    test "mark a tab with errors with a red dot and a screen-reader note" do
      doc = render_bar(panel_tabs(), "details")

      assert [_dot] =
               Floki.find(doc, "#test-tabs-tab-booking span.bg-red-500[aria-hidden='true']")

      assert Floki.text(Floki.find(doc, "#test-tabs-tab-booking .sr-only")) =~
               "This tab contains errors"

      assert Floki.find(doc, "#test-tabs-tab-details span.bg-red-500") == []
    end

    test "render a disabled tab as a disabled button outside the tab order" do
      tabs = [%{id: "a", label: "A"}, %{id: "b", label: "B", disabled: true, badge: "Off"}]
      doc = render_bar(tabs, "a")

      assert attr_of(doc, "#test-tabs-tab-b", "disabled") != []
      assert attr_of(doc, "#test-tabs-tab-b", "tabindex") == ["-1"]
      assert Floki.text(Floki.find(doc, "#test-tabs-tab-b")) =~ "Off"
    end
  end

  describe "link tabs" do
    test "render as navigation links, the current one marked as the page" do
      doc = render_bar(link_tabs(), :video)

      assert [{"nav", _attrs, _children}] = Floki.find(doc, "#test-tabs")
      assert attr_of(doc, "#test-tabs", "role") == []
      assert Floki.find(doc, "[role='tab']") == []

      assert attr_of(doc, "#test-tabs-tab-calendars", "href") == ["/x?tab=calendars"]
      assert attr_of(doc, "#test-tabs-tab-calendars", "data-phx-link") == ["patch"]

      assert attr_of(doc, "#test-tabs-tab-video", "aria-current") == ["page"]
      assert attr_of(doc, "#test-tabs-tab-calendars", "aria-current") == []
      assert attr_of(doc, "#test-tabs-tab-payments", "aria-current") == []
    end

    test "show a count pill and a status dot in the tone's colour" do
      doc = render_bar(link_tabs(), :calendars)

      assert Floki.text(Floki.find(doc, "#test-tabs-tab-calendars span.tabular-nums")) =~ "3"
      assert Floki.find(doc, "#test-tabs-tab-payments span.tabular-nums") == []

      assert [_dot] =
               Floki.find(doc, "#test-tabs-tab-video span.bg-amber-500[aria-hidden='true']")

      assert Floki.text(Floki.find(doc, "#test-tabs-tab-video .sr-only")) =~
               "Warning - needs attention"

      assert Floki.find(doc, "#test-tabs-tab-calendars span.bg-amber-500") == []
    end
  end

  describe "overflow" do
    test "keeps the tabs on one sideways-scrolling row by default" do
      doc = render_bar(panel_tabs(), "details")
      [class] = attr_of(doc, "#test-tabs", "class")

      assert class =~ "flex-nowrap"
      assert class =~ "overflow-x-auto"
      refute class =~ "flex-wrap"
      # The edge fade the hook switches on is part of the strip's classes.
      assert class =~ "data-[overflow=end]:[mask-image:"
    end

    test "wraps instead when asked, for strips whose tabs open a menu" do
      doc = render_bar(panel_tabs(), "details", %{overflow: :wrap})
      [class] = attr_of(doc, "#test-tabs", "class")

      assert class =~ "flex-wrap"
      refute class =~ "overflow-x-auto"
    end
  end

  describe "mixed entries" do
    test "raise when link tabs and panel tabs share a strip" do
      tabs = [%{id: "a", label: "A", patch: "/a"}, %{id: "b", label: "B"}]

      assert_raise ArgumentError, ~r/mixes link tabs/, fn -> render_bar(tabs, "a") end
    end
  end

  describe "slots and per-tab colour" do
    test "render trailing controls outside the tablist" do
      assigns = %{}

      doc =
        ~H"""
        <Navigation.tab_bar id="s" aria_label="S" tabs={[%{id: "a", label: "A"}]} active_tab="a">
          <:trailing><button id="add-thing">Add</button></:trailing>
        </Navigation.tab_bar>
        """
        |> rendered_to_string()
        |> Floki.parse_fragment!()

      assert [_button] = Floki.find(doc, "#add-thing")
      assert Floki.find(doc, "#s #add-thing") == []
    end

    test "render the tab action inside the active tab only, given that tab" do
      assigns = %{}

      doc =
        ~H"""
        <Navigation.tab_bar
          id="s"
          aria_label="S"
          tabs={[%{id: "a", label: "A"}, %{id: "b", label: "B"}]}
          active_tab="b"
        >
          <:tab_action :let={tab}><span class="tab-menu">menu for {tab.id}</span></:tab_action>
        </Navigation.tab_bar>
        """
        |> rendered_to_string()
        |> Floki.parse_fragment!()

      assert [menu] = Floki.find(doc, "#s .tab-menu")
      assert Floki.text(menu) =~ "menu for b"

      # It shares the selected tab's wrapper, beside (not inside) the button.
      [wrapper] =
        Enum.filter(Floki.find(doc, "#s [role='presentation']"), fn el ->
          Floki.find(el, "#s-tab-b") != []
        end)

      assert [_menu] = Floki.find(wrapper, ".tab-menu")
      assert Floki.find(doc, "#s-tab-b .tab-menu") == []
    end

    test "use a tab's accent when it is active and its dot while it is not" do
      tabs = [
        %{id: "a", label: "A", accent: "bg-violet-600 text-white", dot: "bg-violet-400"},
        %{id: "b", label: "B", accent: "bg-amber-600 text-white", dot: "bg-amber-400"}
      ]

      doc = render_bar(tabs, "a")

      wrapper_class = fn id ->
        doc
        |> Floki.find("#test-tabs [role='presentation']")
        |> Enum.find(&(Floki.find(&1, "#test-tabs-tab-#{id}") != []))
        |> Floki.attribute("class")
        |> hd()
      end

      assert wrapper_class.("a") =~ "bg-violet-600"
      refute wrapper_class.("a") =~ "from-turquoise-600"
      refute wrapper_class.("b") =~ "bg-amber-600"

      assert Floki.find(doc, "#test-tabs-tab-a span.bg-violet-400") == []
      assert [_dot] = Floki.find(doc, "#test-tabs-tab-b span.bg-amber-400")
    end
  end
end
