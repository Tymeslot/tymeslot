defmodule TymeslotWeb.Themes.Quill.Theme do
  @moduledoc """
  Quill: glassmorphism design with a 4-step booking flow.
  """

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Quill.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/quill-theme-preview.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "Glass morphism design with elegant transparency effects and a 4-step booking flow."
      ),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "My clients should feel they are booking someone established. The page should look as considered as my work."
      ),
    axes: [
      flow: :paged_wizard,
      entry: :meeting_type_first,
      spatial: :wide_card,
      time_view: :month_grid,
      conversion: :atmosphere,
      voice: :polished,
      surface: :glass
    ]

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate onboarding_preview(assigns),
    to: TymeslotWeb.Themes.Quill.OnboardingPreview,
    as: :render
end
