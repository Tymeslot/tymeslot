defmodule TymeslotWeb.HomepageLive do
  use TymeslotWeb, :live_view

  alias TymeslotWeb.Components.SiteComponents
  alias TymeslotWeb.HomepageLive.CTASection
  alias TymeslotWeb.HomepageLive.FeaturesSection
  alias TymeslotWeb.HomepageLive.HeroSection
  alias TymeslotWeb.HomepageLive.HowItWorksSection
  alias TymeslotWeb.HomepageLive.ThemesSection
  alias TymeslotWeb.HomepageLive.WhyTymeslotSection
  alias TymeslotWeb.Live.Shared.LiveHelpers

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, session, socket) do
    socket =
      socket
      |> assign(:page_title, "Tymeslot - Professional Meeting Scheduling")
      |> LiveHelpers.assign_current_user(session)

    {:ok, socket}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-gray-50 via-white to-gray-100">
      <!-- Navigation -->
      <SiteComponents.navigation current_user={@current_user} />

    <!-- Hero Section -->
      <.live_component
        module={HeroSection}
        id="hero-section"
        current_user={@current_user}
      />

    <!-- Features Section -->
      <.live_component module={FeaturesSection} id="features-section" />

    <!-- Beautiful Themes Section -->
      <.live_component module={ThemesSection} id="themes-section" />

    <!-- How It Works Section -->
      <.live_component module={HowItWorksSection} id="how-it-works-section" />

    <!-- Why Tymeslot Section -->
      <.live_component module={WhyTymeslotSection} id="why-tymeslot-section" />

    <!-- CTA Section -->
      <.live_component module={CTASection} id="cta-section" current_user={@current_user} />

    <!-- Footer -->
      <SiteComponents.site_footer />
    </div>
    """
  end
end
