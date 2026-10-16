defmodule TymeslotWeb.ThemeTestMatrix do
  @moduledoc """
  Per-theme test metadata, keyed by theme id.

  The shared suites iterate this module instead of listing themes by hand, so
  a theme added to `Tymeslot.Themes.Catalog` is exercised by them once it has
  an entry here. `TymeslotWeb.ThemeTestMatrixTest` fails until it does.

  `registered/0` and `registered_ids/0` are every theme, including the
  test-only fixture themes (registered through `:extra_themes` in
  `config/test.exs`). The booking, approval and slot-taken (race) suites, the
  markup contract test and `TymeslotWeb.BookingDriver`'s tests run those: a
  fixture renders the approval notice and the confirmation status, and books
  through the markup contract like any other theme. A fixture has no
  stylesheet of its own. Besides the fixture (`"99"`) and the showcase
  (`"97"`), the test-only themes are the journey fixtures
  (`test/support/journey_fixtures/`: `"96"` Fixture Scroll, `"95"` Fixture
  Talk and `"94"` Fixture Express), whose journeys are their own
  (`journey: :custom`).

  `all/0` and `ids/0` are the shipped themes alone, for the suites tied to
  their own design (deep links, sort order, cancel pages, accessibility, the
  e2e embed matrix).

  `ids_where/1` narrows `ids/0` to the themes whose customisation spec passes
  a predicate, for a suite that stores one option group's settings (a preset
  scheme, a background kind) and so means only the themes that offer them.
  The spec decides, not a field here, so the filter cannot disagree with what
  the theme renders.

  Fields:

    * `:id`, `:key` - as in the catalogue.
    * `:slug` - the key as a string: usernames, test names and the
      `/themes/<slug>/...` payment-return URLs.
    * `:name` - the display name, for failure messages.
    * `:wrapper_class` - the class on the theme's outermost wrapper, whose
      presence proves the theme's own LiveView rendered rather than the
      dispatcher's fallback card.
    * `:video_background` - whether the theme offers a video background, and
      so renders the background motion toggle.
    * `:pins_schedule_actions` - whether the schedule step is locked to the
      viewport with its actions row pinned on-screen (Quill's app shell).
    * `:schedule_view` - what the schedule step picks a time with:
      `:calendar` (a month or week calendar of days, then the chosen day's
      times, as Quill and Rhythm) or `:week_grid` (the shared `WeekGrid`, a
      week of times with one click per time). `TymeslotWeb.BookingDriver`
      picks a time from either through the markup contract; the tests of the
      calendar's own day buttons run for `:calendar` themes only.
    * `:selected_duration_selector` - matches the overview's
      `[data-testid='duration-option']` card only while it is selected. Each
      theme marks the selection its own way (on the button, or on a wrapper
      around it), so a shared assertion reads the selector from here.
    * `:journey` - `:classic` for a theme on the classic journey (the
      `steps:` form, one page per step) or `:custom` for one declaring its
      own `journey:`. The booking, approval and slot-taken suites, the
      markup contract test and `TymeslotWeb.BookingDriver`'s booking tests
      run every registered theme; only a suite that asserts one page per
      step filters on `journey: :classic`.
    * `:fixture` - a test-only theme: left out of `all/0` (and so of the
      suites tied to the shipped themes' own design and the e2e embed
      matrix), but part of `registered/0`, which the booking, approval and
      race suites, the markup contract test and the driver tests run.
  """

  alias Tymeslot.Themes.Catalog

  @type entry :: %{
          id: String.t(),
          key: atom(),
          slug: String.t(),
          name: String.t(),
          wrapper_class: String.t(),
          video_background: boolean(),
          pins_schedule_actions: boolean(),
          schedule_view: :calendar | :week_grid,
          selected_duration_selector: String.t(),
          journey: :classic | :custom,
          fixture: boolean()
        }

  @themes %{
    "1" => %{
      id: "1",
      key: :quill,
      slug: "quill",
      name: "Quill",
      wrapper_class: "quill-theme-wrapper",
      video_background: true,
      pins_schedule_actions: true,
      schedule_view: :calendar,
      selected_duration_selector: "[data-testid='duration-option'].duration-card--selected",
      journey: :classic,
      fixture: false
    },
    "2" => %{
      id: "2",
      key: :rhythm,
      slug: "rhythm",
      name: "Rhythm",
      wrapper_class: "rhythm-theme-wrapper",
      video_background: true,
      pins_schedule_actions: false,
      schedule_view: :calendar,
      selected_duration_selector: ".duration-card.selected [data-testid='duration-option']",
      journey: :classic,
      fixture: false
    },
    "96" => %{
      id: "96",
      key: :fixture_scroll,
      slug: "fixture_scroll",
      name: "Fixture Scroll",
      wrapper_class: "journey-fixture-scroll",
      video_background: false,
      pins_schedule_actions: false,
      schedule_view: :calendar,
      selected_duration_selector: "[data-fact='meeting_type'][aria-pressed='true']",
      journey: :custom,
      fixture: true
    },
    "94" => %{
      id: "94",
      key: :fixture_express,
      slug: "fixture_express",
      name: "Fixture Express",
      wrapper_class: "journey-fixture-express",
      video_background: false,
      pins_schedule_actions: false,
      schedule_view: :week_grid,
      selected_duration_selector: "[data-fact='meeting_type'][aria-pressed='true']",
      journey: :custom,
      fixture: true
    },
    "95" => %{
      id: "95",
      key: :fixture_talk,
      slug: "fixture_talk",
      name: "Fixture Talk",
      wrapper_class: "journey-fixture-talk",
      video_background: false,
      pins_schedule_actions: false,
      schedule_view: :calendar,
      selected_duration_selector: "[data-fact='meeting_type'][aria-pressed='true']",
      journey: :custom,
      fixture: true
    },
    "97" => %{
      id: "97",
      key: :showcase,
      slug: "showcase",
      name: "Showcase",
      wrapper_class: "fixture-theme-wrapper",
      video_background: false,
      pins_schedule_actions: false,
      schedule_view: :week_grid,
      selected_duration_selector: "[data-testid='duration-option'][aria-pressed='true']",
      journey: :classic,
      fixture: true
    },
    "99" => %{
      id: "99",
      key: :fixture,
      slug: "fixture",
      name: "Fixture",
      wrapper_class: "fixture-theme-wrapper",
      video_background: false,
      pins_schedule_actions: false,
      schedule_view: :week_grid,
      selected_duration_selector: "[data-testid='duration-option'][aria-pressed='true']",
      journey: :classic,
      fixture: true
    }
  }

  @doc """
  Every shipped theme's entry (no fixtures), in numeric id order: for the
  suites tied to the shipped themes' own design (deep links, sort order,
  cancel pages, accessibility). The booking, approval and race suites run
  `registered/0`.
  """
  @spec all() :: [entry()]
  def all, do: Enum.reject(registered(), & &1.fixture)

  @doc "Every shipped theme id, in numeric order."
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(all(), & &1.id)

  @doc """
  The shipped theme ids whose customisation spec passes `fun`, in numeric
  order: for a suite that exercises one option group's settings and so runs
  only for the themes that offer them.
  """
  @spec ids_where((module() -> boolean())) :: [String.t()]
  def ids_where(fun) when is_function(fun, 1) do
    Enum.filter(ids(), fn id ->
      {:ok, spec} = Catalog.customization_spec(id)
      fun.(spec)
    end)
  end

  @doc "Every registered theme's entry, fixtures included, in numeric id order."
  @spec registered() :: [entry()]
  def registered, do: @themes |> Map.values() |> Enum.sort_by(&String.to_integer(&1.id))

  @doc "Every registered theme id, fixtures included, in numeric order."
  @spec registered_ids() :: [String.t()]
  def registered_ids, do: Enum.map(registered(), & &1.id)

  @doc "One theme's entry; raises for an id the matrix does not know."
  @spec fetch!(String.t()) :: entry()
  def fetch!(id), do: Map.fetch!(@themes, id)
end
