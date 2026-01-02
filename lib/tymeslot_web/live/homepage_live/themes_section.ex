defmodule TymeslotWeb.HomepageLive.ThemesSection do
  use TymeslotWeb, :live_component

  # Theme data
  @themes [
    %{
      id: 1,
      name: "Quill",
      title: "Quill - Professional Glassmorphism",
      description: "Professional Glassmorphism",
      image: "/images/ui/theme-previews/quill-theme-preview.webp",
      alt: "Quill Theme Preview - Glass morphism booking flow",
      fallback_gradient: "from-purple-100 to-teal-100",
      fallback_color: "bg-teal-500",
      features: [
        "Elegant glass morphism with blur effects",
        "Multi-page booking flow with progress indicators",
        "Custom backgrounds: images, gradients, colors",
        "Perfect for professional services"
      ]
    },
    %{
      id: 2,
      name: "Rhythm",
      title: "Rhythm - Immersive Experience",
      description: "Immersive Experience",
      image: "/images/ui/theme-previews/rhythm-theme-preview.webp",
      alt: "Rhythm Theme Preview - Video background sliding flow",
      fallback_gradient: "from-purple-100 to-pink-100",
      fallback_color: "bg-purple-500",
      features: [
        "Video backgrounds with crossfade technology",
        "Sliding interface with smooth transitions",
        "Connection-aware video loading",
        "Perfect for creative professionals"
      ]
    }
  ]

  # Customization options
  @customization_options [
    %{icon: "🎨", label: "Custom Colors"},
    %{icon: "🖼️", label: "Background Images"},
    %{icon: "🎬", label: "Video Backgrounds"},
    %{icon: "🌈", label: "Gradient Options"}
  ]

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assign(assigns,
        themes: @themes,
        customization_options: @customization_options
      )

    ~H"""
    <section class="py-20 relative overflow-hidden bg-gradient-to-br from-gray-50 to-white">
      <div class="container mx-auto px-6">
        <h2 class="text-3xl md:text-4xl font-bold text-gray-800 text-center mb-4">
          <span class="turquoise-accent">2 Beautiful Themes</span>, More Coming Soon
        </h2>
        <p class="text-lg text-gray-600 text-center mb-12 max-w-3xl mx-auto">
          Choose the perfect booking experience for your brand. Both themes are fully customizable with backgrounds, colors, and your personal touch.
        </p>

        <div class="grid lg:grid-cols-2 gap-8 max-w-6xl mx-auto">
          <.theme_card :for={theme <- @themes} theme={theme} />
        </div>

        <div class="text-center mt-8">
          <p class="text-gray-600 mb-4">Both themes support extensive customization options</p>
          <p class="text-gray-500 text-sm mb-4">
            Demo mode: Test all features without creating real bookings or sending emails
          </p>
          <div class="flex flex-wrap gap-4 justify-center">
            <.customization_badge :for={option <- @customization_options} {option} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  # Theme card component
  defp theme_card(assigns) do
    ~H"""
    <div class="glass-card overflow-hidden group hover-lift">
      <div class="relative h-64 bg-gray-100 overflow-hidden">
        <img
          src={@theme.image}
          alt={@theme.alt}
          class="w-full h-full object-cover transition-transform duration-300 group-hover:scale-105"
          onerror="this.style.display='none'; this.nextElementSibling.style.display='flex'"
        />
        <!-- Fallback when image fails to load -->
        <div
          class={"w-full h-full bg-gradient-to-br #{@theme.fallback_gradient} flex items-center justify-center"}
          style="display: none;"
        >
          <div class="text-center p-4">
            <div class={"w-16 h-16 #{@theme.fallback_color} rounded-lg mx-auto mb-3 flex items-center justify-center"}>
              <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <%= if @theme.name == "Quill" do %>
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                  />
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
                  />
                <% else %>
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M7 4v16l13-8L7 4z"
                  />
                <% end %>
              </svg>
            </div>
            <p class="text-lg font-semibold text-gray-700">{@theme.name} Theme</p>
            <p class="text-sm text-gray-600 mt-1">{@theme.description}</p>
          </div>
        </div>
      </div>
      <div class="p-6">
        <h3 class="text-xl font-bold text-gray-800 mb-3">
          {@theme.title}
        </h3>
        <ul class="space-y-2 text-gray-600 mb-4">
          <li :for={feature <- @theme.features} class="flex items-start gap-2">
            <span class="text-turquoise-500 mt-0.5">✓</span>
            <span>{feature}</span>
          </li>
        </ul>
        <div class="mt-4">
          <.link
            href={"/demo-theme-#{@theme.id}"}
            target="_blank"
            rel="noopener noreferrer"
            class="glass-button px-4 py-2 inline-flex items-center gap-2 text-sm hover-grow"
          >
            <span>Try Demo</span>
            <svg class="w-3 h-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
              />
            </svg>
          </.link>
        </div>
      </div>
    </div>
    """
  end

  # Customization badge component
  defp customization_badge(assigns) do
    ~H"""
    <div class="glass-button px-4 py-2 text-sm" style="cursor: default;">
      <span class="mr-2">{@icon}</span> {@label}
    </div>
    """
  end
end
