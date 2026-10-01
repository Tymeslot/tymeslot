defmodule TymeslotWeb.ThemeTestMatrix do
  @moduledoc """
  Per-theme test metadata, keyed by theme id.

  The shared flow suites iterate `all/0` instead of listing themes by hand, so
  a theme added to `Tymeslot.Themes.Catalog` is exercised by every one of them
  once it has an entry here. `TymeslotWeb.ThemeTestMatrixTest` fails until it
  does.

  `all/0` and `ids/0` are the shipped themes. `registered/0` and
  `registered_ids/0` add the test-only fixture themes (registered through
  `:extra_themes` in `config/test.exs`), which have no booking UI beyond the
  contract and no stylesheet; the suites that hold a theme to the contract
  iterate those instead.

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
      week of times with one click per time). The shared flow helpers pick a
      time from either; the tests of the calendar's own day buttons run for
      `:calendar` themes only.
    * `:selected_duration_selector` - matches the overview's
      `[data-testid='duration-option']` card only while it is selected. Each
      theme marks the selection its own way (on the button, or on a wrapper
      around it), so a shared assertion reads the selector from here.
    * `:fixture` - a test-only theme: left out of `all/0`, and so of every
      flow suite and the e2e embed matrix.
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
      fixture: false
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
      fixture: true
    }
  }

  @doc "Every shipped theme's entry, in numeric id order: the themes the flow suites run."
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
