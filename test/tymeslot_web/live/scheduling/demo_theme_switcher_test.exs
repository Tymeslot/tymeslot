defmodule TymeslotWeb.Live.Scheduling.DemoThemeSwitcherTest do
  @moduledoc """
  The theme switcher a demo booking page offers
  (`Shared.Components.DemoThemeSwitcher`), and the chosen theme surviving the
  flow's redirects. Only a demo provider makes a page a demo: with the
  default `Tymeslot.Demo.NoOp`, as on every self-hosted install, no page
  shows a switcher.
  """
  use TymeslotWeb.ConnCase, async: false

  @moduletag :themes
  @moduletag :live

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.ThemeBookingFlowHelpers, only: [seed_booking_account: 3]

  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.Themes.Shared.Components.DemoThemeSwitcher

  @switcher "[data-testid='demo-theme-switcher']"

  defmodule DemoProvider do
    @moduledoc false
    # The default provider's answer to everything but one question: the
    # organiser `switcher-demo` is a demo one.
    @behaviour Tymeslot.Demo.Behaviour

    for {name, arity} <- Tymeslot.Demo.Behaviour.behaviour_info(:callbacks),
        name != :demo_profile? do
      args = Macro.generate_arguments(arity, __MODULE__)

      @impl Tymeslot.Demo.Behaviour
      def unquote(name)(unquote_splicing(args)),
        do: Tymeslot.Demo.NoOp.unquote(name)(unquote_splicing(args))
    end

    @impl Tymeslot.Demo.Behaviour
    def demo_profile?(%{username: "switcher-demo"}), do: true
    def demo_profile?(_profile), do: false
  end

  # The locale switch's redirect, as its path and query. The visitor's
  # tracking hash (`LiveHelpers.Tracking`) rides along on every page and is
  # not what these tests are about.
  defp locale_switch(view) do
    assert {:error, {:redirect, %{to: to}}} =
             render_click(view, "change_locale", %{"locale" => "de"})

    %URI{path: path, query: query} = URI.parse(to)
    {path, query |> URI.decode_query() |> Map.delete("visitor_hash")}
  end

  setup do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _integration, _from, _to ->
      {:ok, []}
    end)

    seed_booking_account("1", "switcher-demo", "Etc/UTC")
    :ok
  end

  describe "active_options/1" do
    test "offers only active themes, in id order" do
      themes = %{
        ten: %{id: "10", name: "Ten", status: :active},
        old: %{id: "3", name: "Old", status: :deprecated},
        next: %{id: "4", name: "Next", status: :beta},
        one: %{id: "1", name: "One", status: :active}
      }

      assert DemoThemeSwitcher.active_options(themes) == [{"One", "1"}, {"Ten", "10"}]
    end

    test "by default matches the pickers' themes while none is deprecated" do
      assert DemoThemeSwitcher.active_options() == ThemeInfo.theme_options()
    end
  end

  describe "with the default demo provider" do
    test "no booking page shows a switcher", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/switcher-demo?theme=2")

      refute has_element?(view, @switcher)
    end

    test "a locale switch drops ?theme=, as on any ordinary page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/switcher-demo?theme=2")

      assert locale_switch(view) == {"/switcher-demo", %{"locale" => "de"}}
    end
  end

  describe "on a demo page" do
    setup do
      previous = Application.get_env(:tymeslot, :demo_provider)
      Application.put_env(:tymeslot, :demo_provider, DemoProvider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:tymeslot, :demo_provider, previous),
          else: Application.delete_env(:tymeslot, :demo_provider)
      end)

      :ok
    end

    test "lists every theme the pickers offer, each linking this page in it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/switcher-demo?theme=2")

      for {name, id} <- ThemeInfo.theme_options() do
        assert has_element?(view, "#{@switcher} a[href='/switcher-demo?theme=#{id}']", name)
      end

      assert has_element?(view, "#{@switcher} a[aria-current='page'][data-theme-option='2']")
      refute has_element?(view, "#{@switcher} a[aria-current='page'][data-theme-option='1']")
    end

    test "a locale switch keeps a theme other than the organiser's", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/switcher-demo?theme=2")

      assert locale_switch(view) == {"/switcher-demo", %{"locale" => "de", "theme" => "2"}}
    end

    test "a locale switch on the organiser's own theme adds none", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/switcher-demo")

      assert locale_switch(view) == {"/switcher-demo", %{"locale" => "de"}}
    end

    test "the booking step's redirect back to the schedule keeps it", %{conn: conn} do
      assert {:error, {:redirect, %{to: to}}} =
               live(conn, "/switcher-demo/30-minutes/book?theme=2")

      assert %URI{path: "/switcher-demo/" <> _slug, query: "theme=2"} = URI.parse(to)
    end

    test "an unknown meeting type's redirect to the overview keeps it", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/switcher-demo?theme=2"}}} =
               live(conn, "/switcher-demo/no-such-type?theme=2")
    end
  end
end
