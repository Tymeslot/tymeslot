defmodule TymeslotWeb.Themes.Paper.Theme do
  @moduledoc """
  Paper: a calm, flat booking page. One card on the palette's canvas, in two
  screens: the meeting types, then the time and the details together; a
  colour palette with a light and a dark set, and a light, dark or automatic
  colour mode. Its meeting,
  poll and payment pages are the shared defaults (`Shared.DefaultPages`)
  inside its page shell.
  """
  alias TymeslotWeb.Themes.Paper.Pages

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Paper.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/paper-theme-preview.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "A calm, flat booking page: choose a meeting type, then pick a time and book on one screen. Light and dark modes in the colour palette you choose."
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
