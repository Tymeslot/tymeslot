defmodule TymeslotWeb.HomepageLive.WhyTymeslotSection do
  use TymeslotWeb, :live_component

  # Benefits data
  @benefits [
    %{
      icon: "🎯",
      title: "No Double-Booking",
      description:
        "Real-time sync across all 4 calendar providers prevents conflicts automatically"
    },
    %{
      icon: "🌐",
      title: "Self-Hosted Option",
      description:
        "Deploy via Docker on any server or use Cloudron. Your data stays under your control"
    },
    %{
      icon: "🔒",
      title: "Open Source",
      description:
        "MIT licensed with active development. Audit the code, contribute features, or fork it"
    }
  ]

  # Technology indicators
  @tech_stack [
    %{name: "Elixir", description: "Fault-tolerant runtime"},
    %{name: "Phoenix LiveView", description: "Real-time UI"},
    %{name: "PostgreSQL", description: "Reliable database"}
  ]

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    assigns =
      assign(assigns,
        benefits: @benefits,
        tech_stack: @tech_stack
      )

    ~H"""
    <section class="py-20 relative overflow-hidden">
      <div class="container mx-auto px-6">
        <h2 class="text-3xl md:text-4xl font-bold text-gray-800 text-center mb-12">
          Why You'll Love <span class="turquoise-accent">Tymeslot</span>
        </h2>
        <div class="grid md:grid-cols-3 gap-8 max-w-6xl mx-auto">
          <.benefit_card :for={benefit <- @benefits} {benefit} />
        </div>

    <!-- Trust Indicators -->
        <div class="mt-16 text-center">
          <p class="text-gray-600 mb-6">Built with enterprise-grade technology</p>
          <div class="flex flex-wrap gap-6 justify-center items-center">
            <.tech_badge :for={tech <- @tech_stack} {tech} />
          </div>
        </div>
      </div>
    </section>
    """
  end

  # Benefit card component
  defp benefit_card(assigns) do
    ~H"""
    <div class="glass-card p-8 text-center">
      <div class="w-20 h-20 mx-auto mb-6 glass-button rounded-full flex items-center justify-center">
        <span class="text-4xl">{@icon}</span>
      </div>
      <h3 class="text-xl font-bold text-gray-800 mb-3">{@title}</h3>
      <p class="text-gray-600 leading-relaxed">
        {@description}
      </p>
    </div>
    """
  end

  # Technology badge component
  defp tech_badge(assigns) do
    ~H"""
    <div class="glass-button px-6 py-3" style="cursor: default;">
      <span class="font-semibold turquoise-accent">{@name}</span>
      <span class="text-gray-600 ml-2">{@description}</span>
    </div>
    """
  end
end
