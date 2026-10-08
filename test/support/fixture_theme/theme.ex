defmodule TymeslotWeb.Test.FixtureTheme.Theme do
  @moduledoc """
  A test-only booking theme, registered by `config/test.exs` through
  `:extra_themes`. It is shaped unlike Quill and Rhythm on purpose (a light
  palette with no presets, no background, an option group, a dashboard panel
  and an event of its own) and a voice of its own for five shared booking
  lines, and has no stylesheet; `theme_openness_test.exs` uses it to prove a
  new theme attaches without editing shared code. It
  borrows Quill's preview image, since the contract test wants one that
  exists. It declares a `page_shell`, so its meeting, poll and payment pages
  are the shared defaults (`Shared.DefaultPages`).
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.FixtureTheme.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "A booking page built only from the shared parts, to prove a theme needs nothing more."
      ),
    axes: [
      flow: :paged_wizard,
      entry: :meeting_type_first,
      spatial: :centred_card,
      time_view: :week_grid,
      conversion: :bio_and_cover,
      voice: :neutral,
      surface: :flat_light_card
    ],
    page_shell: &Pages.page_shell/1,
    voice: TymeslotWeb.Test.FixtureTheme.Voice,
    option_panels: %{
      Tymeslot.Test.FixtureThemeSpec.Emblem => TymeslotWeb.Test.FixtureTheme.EmblemPanel,
      Tymeslot.Test.FixtureThemeSpec.Clips => TymeslotWeb.Test.FixtureTheme.ClipsPanel
    }
end
