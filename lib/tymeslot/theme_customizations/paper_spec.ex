defmodule Tymeslot.ThemeCustomizations.PaperSpec do
  @moduledoc """
  Customisation spec of the Paper theme: a colour palette, a colour mode
  (light, dark, or the visitor's own), a font, a corner style, a calendar
  view (a month calendar, or a week of free times on one screen) and a
  logo. Paper has no background option: the palette's canvas is the page.

  The palettes are Quill and Rhythm's colour families, each with a light set
  on a pale tint of its colour and a dark set (`follow_os: true`); the colour
  mode picks between them. A custom seed derives both sets from one colour
  (`seed_mode: :light`). The groups are the shared ones, in the canonical
  order, so the generated `changeset/2`, `asset_fields/0`, `tokens/2` and
  `onboarding_choices/0` stand: the font and radius add their variables, and
  the calendar view and the logo their media (the schedule screen reads
  `media[:calendar_view]`).
  """
  use Tymeslot.ThemeCustomizations.Spec

  alias Tymeslot.ThemeCustomizations.Options.CalendarView
  alias Tymeslot.ThemeCustomizations.Options.ColourMode
  alias Tymeslot.ThemeCustomizations.Options.Font
  alias Tymeslot.ThemeCustomizations.Options.Logo
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Options.Radius
  alias Tymeslot.ThemeCustomizations.Spec

  @palettes ~w(paper_turquoise paper_arctic paper_purple paper_sunset paper_ocean paper_forest paper_rose paper_monochrome)
  @fonts ~w(system inter plex)

  @impl Spec
  def option_groups,
    do: [
      %{key: :palette, module: Palette, schemes: @palettes, seed_mode: :light, follow_os: true},
      %{key: :colour_mode, module: ColourMode, default: "auto"},
      %{key: :font, module: Font, presets: @fonts, default: "system"},
      %{key: :radius, module: Radius, default: "soft"},
      %{key: :calendar_view, module: CalendarView, default: "month"},
      %{key: :logo, module: Logo}
    ]

  @impl Spec
  def defaults,
    do: %{
      color_scheme: "paper_turquoise",
      colour_mode: "auto",
      font: "system",
      radius: "soft",
      calendar_view: "month"
    }
end
