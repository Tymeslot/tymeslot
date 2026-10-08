defmodule TymeslotWeb.Test.JourneyFixtures.Express.Theme do
  @moduledoc """
  Fixture Express (`"94"`), a test-only booking theme registered by
  `config/test.exs` through `:extra_themes`: a time-first `Paged` journey. Its
  meeting, poll and payment pages are the shared defaults, through the
  fixture theme's `page_shell`; it borrows Quill's preview image.
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.JourneyFixtures.Express.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "My visitors want the next free time, in two taps."
      ),
    axes: [
      flow: :time_first,
      entry: :time_first,
      spatial: :mobile_first_stack,
      time_view: :next_slots,
      conversion: :none,
      voice: :brisk,
      surface: :utilitarian
    ],
    page_shell: &Pages.page_shell/1
end
