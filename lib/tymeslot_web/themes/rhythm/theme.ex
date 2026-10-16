defmodule TymeslotWeb.Themes.Rhythm.Theme do
  @moduledoc """
  Rhythm: sliding design over a video background with a 4-slide booking flow.
  """

  use TymeslotWeb.Themes.Core.Theme,
    live_view: TymeslotWeb.Themes.Rhythm.Scheduling.Live,
    preview_image: "/images/ui/theme-previews/rhythm-theme-preview.webp",
    description:
      dgettext_noop(
        "dashboard_appearance",
        "Modern sliding design with video background and a 4-slide booking flow."
      ),
    story:
      dgettext_noop(
        "dashboard_appearance",
        "When someone books me, I want them to feel the atmosphere first: motion, mood, then a time."
      ),
    axes: [
      flow: :paged_wizard,
      entry: :meeting_type_first,
      spatial: :centred_card,
      time_view: :week_strip,
      conversion: :atmosphere,
      voice: :polished,
      surface: :glass
    ]

  @impl TymeslotWeb.Themes.Core.Behaviour
  defdelegate onboarding_preview(assigns),
    to: TymeslotWeb.Themes.Rhythm.OnboardingPreview,
    as: :render
end
