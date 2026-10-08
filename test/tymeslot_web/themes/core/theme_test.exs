defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Meeting.Reschedule do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:reschedule, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Meeting.Cancel do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:cancel, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Meeting.CancelConfirmed do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:cancel_confirmed, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Poll.Voting do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:poll, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Payment.Processing do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:processing, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Payment.Cancelled do
  @moduledoc false
  @spec render(map()) :: {atom(), map()}
  def render(assigns), do: {:cancelled, assigns}
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Fixture.Theme do
  @moduledoc false
  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Core.ThemeTest.Fixture.Live,
    preview_image: "/images/fixture.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "Modern sliding design with video background and a 4-slide booking flow."
      ),
    story: dgettext_noop("dashboard_appearance", "A theme for the macro's own tests."),
    axes: [
      surface: :flat_light_card,
      voice: :neutral,
      flow: :paged_wizard,
      entry: :meeting_type_first,
      spatial: :centred_card,
      time_view: :month_grid,
      conversion: :none
    ]
end

defmodule TymeslotWeb.Themes.Core.ThemeTest.Overriding.Theme do
  @moduledoc false
  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Core.ThemeTest.Overriding.Live,
    preview_image: "/images/fixture.webp",
    option_panels: %{
      TymeslotWeb.Themes.Core.ThemeTest.Overriding.Group =>
        TymeslotWeb.Themes.Core.ThemeTest.Overriding.Panel
    },
    description:
      dgettext_noop(
        "dashboard_appearance",
        "Modern sliding design with video background and a 4-slide booking flow."
      ),
    story: dgettext_noop("dashboard_appearance", "A theme for the macro's own tests."),
    axes: [
      surface: :flat_light_card,
      voice: :neutral,
      flow: :paged_wizard,
      entry: :meeting_type_first,
      spatial: :centred_card,
      time_view: :month_grid,
      conversion: :none
    ]

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_poll_action(_assigns), do: :overridden

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_meeting_action(_assigns, _action), do: :overridden

  @impl TymeslotWeb.Themes.Core.Behaviour
  def render_payment_page(_assigns, _page), do: :overridden
end

defmodule TymeslotWeb.Themes.Core.ThemeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Test.FixtureTheme.Theme, as: RegisteredFixture
  alias TymeslotWeb.Test.FixtureTheme.Voice, as: FixtureVoice
  alias TymeslotWeb.Themes.Core.ThemeTest.Fixture.Theme, as: Fixture
  alias TymeslotWeb.Themes.Core.ThemeTest.Overriding.Theme, as: Overriding

  @assigns %{marker: :assigns}

  @story_source ~s{story: dgettext_noop("dashboard_appearance", "A theme for the macro's own tests.")}

  @axes_source "axes: [flow: :paged_wizard, entry: :meeting_type_first, " <>
                 "spatial: :centred_card, time_view: :month_grid, conversion: :none, " <>
                 "voice: :neutral, surface: :glass]"

  # A theme module's source, named after `name`: the three options every
  # theme has, then `options` (each a `key: value` source), comma-separated.
  defp theme_source(name, options) do
    common = [
      "live_view: Some.Live",
      ~s(preview_image: "/images/fixture.webp"),
      ~s{description: dgettext_noop("dashboard_appearance", "A theme for the macro's own tests.")}
    ]

    """
    defmodule TymeslotWeb.Themes.Core.ThemeTest.#{name}.Theme do
      use TymeslotWeb.Themes.Core.Theme,
        #{Enum.join(common ++ options, ",\n    ")}
    end
    """
  end

  test "declares the theme behaviour" do
    behaviours = Keyword.get_values(Fixture.module_info(:attributes), :behaviour)
    assert TymeslotWeb.Themes.Core.Behaviour in List.flatten(behaviours)
  end

  test "live_view_module/0 returns the :live_view option" do
    assert Fixture.live_view_module() == TymeslotWeb.Themes.Core.ThemeTest.Fixture.Live
  end

  test "metadata/0 carries the preview image and the translated description" do
    Gettext.put_locale(TymeslotWeb.Gettext, "de")

    assert %{preview_image: "/images/fixture.webp", description: description} =
             Fixture.metadata()

    assert description ==
             Gettext.dgettext(
               TymeslotWeb.Gettext,
               "dashboard_appearance",
               "Modern sliding design with video background and a 4-slide booking flow."
             )

    refute description =~ "Modern sliding design"
  end

  test "render_meeting_action/2 dispatches to the theme's Meeting modules" do
    assert Fixture.render_meeting_action(@assigns, :reschedule) == {:reschedule, @assigns}
    assert Fixture.render_meeting_action(@assigns, :cancel) == {:cancel, @assigns}

    assert Fixture.render_meeting_action(@assigns, :cancel_confirmed) ==
             {:cancel_confirmed, @assigns}

    assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
      Fixture.render_meeting_action(@assigns, :invalid)
    end
  end

  test "render_poll_action/1 dispatches to the theme's Poll.Voting" do
    assert Fixture.render_poll_action(@assigns) == {:poll, @assigns}
  end

  test "render_payment_page/2 dispatches to the theme's Payment modules" do
    assert Fixture.render_payment_page(@assigns, :processing) == {:processing, @assigns}
    assert Fixture.render_payment_page(@assigns, :cancelled) == {:cancelled, @assigns}
  end

  test "every render callback can be overridden" do
    assert Overriding.render_poll_action(@assigns) == :overridden
    assert Overriding.render_meeting_action(@assigns, :cancel) == :overridden
    assert Overriding.render_payment_page(@assigns, :processing) == :overridden
  end

  test "option_panels/0 defaults to none" do
    assert Fixture.option_panels() == %{}
  end

  test "option_panels/0 returns the :option_panels option" do
    assert Overriding.option_panels() == %{
             TymeslotWeb.Themes.Core.ThemeTest.Overriding.Group =>
               TymeslotWeb.Themes.Core.ThemeTest.Overriding.Panel
           }
  end

  test "voice/0 defaults to none" do
    assert Fixture.voice() == nil
  end

  test "voice/0 returns the :voice option" do
    assert RegisteredFixture.voice() == FixtureVoice
  end

  # The macro under test runs inside Code.compile_string/1, where the check
  # cannot see it.
  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "rejects a description that is not a dgettext_noop/2 call" do
    assert_raise ArgumentError, ~r/dgettext_noop/, fn ->
      Code.compile_string("""
      defmodule TymeslotWeb.Themes.Core.ThemeTest.BadDescription.Theme do
        use TymeslotWeb.Themes.Core.Theme,
          live_view: Some.Live,
          preview_image: "/images/fixture.webp",
          description: "not translatable"
      end
      """)
    end
  end

  test "story/0 returns the :story option" do
    assert Fixture.story() == "A theme for the macro's own tests."
  end

  test "axes/0 returns the :axes option in the canonical order" do
    assert Fixture.axes() == [
             flow: :paged_wizard,
             entry: :meeting_type_first,
             spatial: :centred_card,
             time_view: :month_grid,
             conversion: :none,
             voice: :neutral,
             surface: :flat_light_card
           ]
  end

  # The macro under test runs inside Code.compile_string/1, where the check
  # cannot see it.
  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "requires a story, as a dgettext_noop/2 call in the description's domain" do
    assert_raise ArgumentError, ~r/needs :story/, fn ->
      Code.compile_string(theme_source("NoStory", [@axes_source]))
    end

    assert_raise ArgumentError, ~r/:story.*dgettext_noop/, fn ->
      Code.compile_string(theme_source("PlainStory", [~s(story: "mine"), @axes_source]))
    end

    assert_raise ArgumentError, ~r/same domain/, fn ->
      Code.compile_string(
        theme_source("OtherDomain", [
          ~s{story: dgettext_noop("booking", "A theme for the macro's own tests.")},
          @axes_source
        ])
      )
    end
  end

  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "requires the seven axes, each with one of its values" do
    assert_raise ArgumentError, ~r/needs :axes/, fn ->
      Code.compile_string(theme_source("NoAxes", [@story_source]))
    end

    assert_raise ArgumentError, ~r/:glassy/, fn ->
      Code.compile_string(
        theme_source("BadAxis", [@story_source, String.replace(@axes_source, ":glass", ":glassy")])
      )
    end
  end

  test "onboarding_preview/1 defaults to the generic mock" do
    html =
      render_component(&Fixture.onboarding_preview/1,
        variant: :thumbnail,
        primary: "#abcdef"
      )

    assert html =~ "#abcdef"
    # The generic thumbnail's two-column chip grid, which neither Quill's nor
    # Rhythm's thumbnail draws.
    assert html =~ "grid grid-cols-2 gap-1"
  end
end
