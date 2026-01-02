defmodule TymeslotWeb.HomepageLive.HeroSection do
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.HeroBookingDemo

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="min-h-screen flex flex-col lg:flex-row">
      <!-- Left Content -->
      <div class="flex-1 flex items-center px-6 py-16 lg:px-12">
        <div class="w-full max-w-xl mx-auto lg:mx-0">
          <h1 class="text-4xl sm:text-5xl lg:text-6xl font-bold text-gray-800 mb-6 leading-tight">
            <span class="turquoise-accent">Beautiful</span> <br /> scheduling,<br /> finally.
          </h1>
          <p class="text-lg sm:text-xl lg:text-2xl text-gray-600 mb-8 font-medium leading-relaxed">
            <span class="text-gray-700 font-semibold">A scheduling tool</span>
            <br /> designed with attention<br /> to every detail.
          </p>
          <div class="flex flex-col sm:flex-row gap-4">
            <%= if @current_user do %>
              <.link navigate={~p"/dashboard"} class="glass-button text-lg px-8 py-4 hover-grow">
                Go to Dashboard
              </.link>
            <% else %>
              <.link navigate={~p"/auth/signup"} class="glass-button text-lg px-8 py-4 hover-grow">
                Start Free Trial
              </.link>
            <% end %>
            <.link
              href="https://github.com/tymeslot/tymeslot"
              target="_blank"
              rel="noopener noreferrer"
              class="glass-button text-lg px-8 py-4 hover-grow flex items-center gap-2"
            >
              <svg class="w-5 h-5" fill="currentColor" viewBox="0 0 24 24">
                <path d="M12 0c-6.626 0-12 5.373-12 12 0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23.957-.266 1.983-.399 3.003-.404 1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576 4.765-1.589 8.199-6.086 8.199-11.386 0-6.627-5.373-12-12-12z" />
              </svg>
              Open Source
            </.link>
          </div>
        </div>
      </div>

    <!-- Right Content - Booking Demo -->
      <div class="flex-1 hero-gradient-bg relative overflow-hidden">
        <!-- Decorative background -->
        <div class="absolute inset-0 hero-bg-pattern pointer-events-none opacity-30"></div>

    <!-- Floating elements -->
        <div class="absolute inset-0 pointer-events-none">
          <div class="floating-element floating-element-1"></div>
          <div class="floating-element floating-element-2"></div>
          <div class="floating-element floating-element-3"></div>
        </div>

    <!-- Demo container -->
        <div class="h-full flex items-center justify-center p-8">
          <div class="w-full max-w-md">
            <.live_component
              module={HeroBookingDemo}
              id="hero-booking-demo"
            />
          </div>
        </div>
      </div>
    </section>
    """
  end
end
