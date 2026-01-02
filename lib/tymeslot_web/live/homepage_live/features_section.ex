defmodule TymeslotWeb.HomepageLive.FeaturesSection do
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.Icons.ProviderIcon

  # Calendar providers data
  @calendar_providers [
    %{provider: "google", name: "Google Calendar"},
    %{provider: "caldav", name: "CalDAV"},
    %{provider: "nextcloud", name: "Nextcloud"}
  ]

  # Video providers data
  @video_providers [
    %{provider: "mirotalk", name: "MiroTalk P2P"},
    %{provider: "google_meet", name: "Google Meet"},
    %{provider: "custom", name: "Custom Links"}
  ]

  # Feature cards data
  @feature_cards [
    %{
      icon: "📧",
      title: "Smart Email System",
      description:
        "MJML responsive templates with .ics attachments. Automatic reminders and delivery tracking."
    },
    %{
      icon: "🌍",
      title: "90+ Timezone Cities",
      description:
        "Automatic detection, DST handling, and intelligent conversions. No mental math required."
    },
    %{
      icon: "🔐",
      title: "Bank-Level Security",
      description: "OAuth 2.0, AES encryption, rate limiting, CSRF protection, and audit logging."
    },
    %{
      icon: "⚡",
      title: "99.9% Uptime Ready",
      description: "Circuit breakers, connection pooling, and graceful degradation on Elixir."
    }
  ]

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assign(assigns,
        calendar_providers: @calendar_providers,
        video_providers: @video_providers,
        feature_cards: @feature_cards
      )

    ~H"""
    <section class="py-20 glass-content">
      <div class="container mx-auto px-6">
        <h2 class="text-3xl md:text-4xl font-bold text-gray-800 text-center mb-4">
          Everything You Need for <span class="turquoise-accent">Seamless Scheduling</span>
        </h2>
        <p class="text-lg text-gray-600 text-center mb-12 max-w-3xl mx-auto">
          Enterprise-grade scheduling that connects with your existing tools, backed by fault-tolerant infrastructure
        </p>

    <!-- Calendar and Video Integration Features - Two columns on desktop -->
        <div class="grid lg:grid-cols-2 gap-8 mb-8">
          <!-- Calendar Integration Feature -->
          <div class="glass-card p-8">
            <div class="flex items-center gap-3 mb-4">
              <div class="text-4xl">📅</div>
              <h3 class="text-xl font-bold text-gray-800">Multi-Calendar Integration</h3>
            </div>
            <p class="text-gray-600 mb-6 leading-relaxed">
              Full synchronization with all major calendar providers. Auto-detects calendars, refreshes OAuth tokens automatically, and prevents double-booking across all platforms.
            </p>
            <div class="space-y-3">
              <.provider_badge
                :for={provider <- @calendar_providers}
                provider={provider}
                type="calendar"
              />
            </div>
          </div>

    <!-- Video Integration Feature -->
          <div class="glass-card p-8">
            <div class="flex items-center gap-3 mb-4">
              <div class="text-4xl">🎥</div>
              <h3 class="text-xl font-bold text-gray-800">Flexible Video Conferencing</h3>
            </div>
            <p class="text-gray-600 mb-6 leading-relaxed">
              Choose from multiple video providers or use custom links. Automatic room creation with separate organizer and attendee access for privacy and control.
            </p>
            <div class="space-y-3">
              <.provider_badge :for={provider <- @video_providers} provider={provider} type="video" />
            </div>
          </div>
        </div>

    <!-- Other Features Grid -->
        <div class="grid md:grid-cols-2 lg:grid-cols-4 gap-6">
          <.feature_card :for={feature <- @feature_cards} {feature} />
        </div>
      </div>
    </section>
    """
  end

  # Provider badge component
  defp provider_badge(assigns) do
    ~H"""
    <div class="flex items-center gap-2 glass-button px-4 py-2" style="cursor: default;">
      <ProviderIcon.provider_icon provider={@provider.provider} type={@type} size="compact" />
      <span class="text-sm font-medium">{@provider.name}</span>
    </div>
    """
  end

  # Feature card component
  defp feature_card(assigns) do
    ~H"""
    <div class="glass-card p-6 text-left hover-lift h-full group relative overflow-hidden">
      <div class="relative z-10">
        <div class="text-4xl mb-3 transform group-hover:scale-110 transition-transform duration-300">
          {@icon}
        </div>
        <h3 class="text-lg font-bold text-gray-800 mb-2 group-hover:text-turquoise-600 transition-colors duration-300">
          {@title}
        </h3>
        <p class="text-sm text-gray-600 leading-relaxed">
          {@description}
        </p>
      </div>
      <div class="absolute -bottom-8 -right-8 w-32 h-32 bg-gradient-to-br from-turquoise-500/10 to-turquoise-600/5 rounded-full blur-xl opacity-0 group-hover:opacity-100 transition-opacity duration-500">
      </div>
    </div>
    """
  end
end
