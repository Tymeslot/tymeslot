defmodule TymeslotWeb.Themes.Folio.Theme do
  @moduledoc """
  Folio: the organiser's page. A cover image, their portrait, name, headline
  and bio in serif type, then the ways to work with them, the calendar, the
  times and the details, each opening below the last on one continuous page
  with a summary bar of what is chosen. Its meeting, poll and payment pages
  are the shared defaults inside Folio's card (`page_shell:`). Its
  onboarding preview is
  `TymeslotWeb.Themes.Folio.OnboardingPreview`.
  """
  alias TymeslotWeb.Themes.Folio.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Folio.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/folio-theme-preview.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "An editorial page that introduces you, with a cover image, your portrait, headline and bio, and serif headings."
      ),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "People book me, not a time slot. Before they pick a date, they should know who I am, what I do, and whether we're a fit."
      ),
    axes: [
      flow: :continuous,
      entry: :person_first,
      spatial: :full_bleed_editorial,
      time_view: :month_grid,
      conversion: :bio_and_cover,
      voice: :personal,
      surface: :editorial_print
    ],
    voice: TymeslotWeb.Themes.Folio.Voice,
    page_shell: &Pages.page_shell/1

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate onboarding_preview(assigns),
    to: TymeslotWeb.Themes.Folio.OnboardingPreview,
    as: :render
end
