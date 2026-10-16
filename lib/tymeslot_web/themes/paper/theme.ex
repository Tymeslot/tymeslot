defmodule TymeslotWeb.Themes.Paper.Theme do
  @moduledoc """
  Paper: a calm, neutral booking page. One card on the tone's canvas with
  everything a booking needs on one screen, one accent colour, and a light,
  dark or automatic colour mode. Its meeting, poll and payment pages are the
  shared defaults (`Shared.DefaultPages`) inside its page shell.
  """
  alias TymeslotWeb.Themes.Paper.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Paper.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/paper-theme-preview.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "A calm, neutral booking page: everything on one screen, light and dark modes and your own accent colour."
      ),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "I don't want my booking page to have a personality. I want it clear, fast and in my colour, so people book and get on with their day."
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
    voice: TymeslotWeb.Themes.Paper.Voice,
    page_shell: &Pages.page_shell/1

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate onboarding_preview(assigns),
    to: TymeslotWeb.Themes.Paper.OnboardingPreview,
    as: :render
end
