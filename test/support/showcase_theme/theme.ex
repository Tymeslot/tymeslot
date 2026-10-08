defmodule TymeslotWeb.Test.ShowcaseTheme.Theme do
  @moduledoc """
  A second test-only booking theme, registered by `config/test.exs` through
  `:extra_themes`. Its spec, `Tymeslot.Test.ShowcaseThemeSpec`, declares
  every shared option group no shipped theme offers yet, so their dashboard
  panels, uploads and booking-page tokens are proved through the real
  routes. Its booking steps are the fixture theme's, and it names the
  fixture's `page_shell`, so its meeting, poll and payment pages are the
  shared defaults (`Shared.DefaultPages`); their test ids carry its own key.
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.FixtureTheme.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "Every shared option at once, to prove each one through the real pages."
      ),
    axes: [
      flow: :paged_wizard,
      entry: :meeting_type_first,
      spatial: :centred_card,
      time_view: :week_grid,
      conversion: :atmosphere,
      voice: :neutral,
      surface: :flat_light_card
    ],
    page_shell: &Pages.page_shell/1
end
