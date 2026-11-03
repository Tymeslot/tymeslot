defmodule TymeslotWeb.Test.JourneyFixtures.Two.Theme do
  @moduledoc """
  Fixture Two (`"93"`), a test-only booking theme registered by
  `config/test.exs` through `:extra_themes`: a `Paged` journey of two
  screens, the meeting types and then one moment that collects the slot, the
  answers and the attendee. Its meeting, poll and payment pages are the
  shared defaults, through the fixture theme's `page_shell`; it borrows
  Quill's preview image.
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.JourneyFixtures.Two.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "One screen to choose, one to book."
      ),
    axes: [
      flow: :two_screen,
      entry: :meeting_type_first,
      spatial: :split_card,
      time_view: :month_grid,
      conversion: :none,
      voice: :neutral,
      surface: :flat_light_card
    ],
    page_shell: &Pages.page_shell/1
end
