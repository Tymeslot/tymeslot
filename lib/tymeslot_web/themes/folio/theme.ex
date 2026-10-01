defmodule TymeslotWeb.Themes.Folio.Theme do
  @moduledoc """
  Folio: the organiser's page. A cover image, their portrait, name, headline
  and bio in serif type, then the meeting types as cards; from the schedule
  step on, a slim cover band above a single-column booker. Its meeting, poll
  and payment pages are the shared defaults inside Folio's card
  (`page_shell:`). Its onboarding preview is
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
    page_shell: &Pages.page_shell/1

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate onboarding_preview(assigns),
    to: TymeslotWeb.Themes.Folio.OnboardingPreview,
    as: :render
end
