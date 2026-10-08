defmodule TymeslotWeb.Test.JourneyFixtures.Talk.Theme do
  @moduledoc """
  Fixture Talk (`"95"`), a test-only booking theme registered by
  `config/test.exs` through `:extra_themes`: a `Transcript` journey whose
  meeting type is chosen for a visitor of an organiser who offers one. Its
  meeting, poll and payment pages are the shared defaults, through the
  fixture theme's `page_shell`; it borrows Quill's preview image.
  """
  alias TymeslotWeb.Test.FixtureTheme.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Test.JourneyFixtures.Talk.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description: dgettext_noop("dashboard_appearance", "Test fixture theme."),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "Booking me should feel like a short conversation, one question at a time."
      ),
    axes: [
      flow: :conversation,
      entry: :meeting_type_first,
      spatial: :chat_column,
      time_view: :day_chips,
      conversion: :none,
      voice: :warm,
      surface: :soft_bubbles
    ],
    page_shell: &Pages.page_shell/1
end
