defmodule TymeslotWeb.HomepageLive.HowItWorksSection do
  use TymeslotWeb, :live_component

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    domain = Application.get_env(:tymeslot, :email)[:domain] || "tymeslot.app"

    steps = [
      %{
        number: "1",
        title: "Create Account",
        description:
          "Sign up with email, Google, or GitHub. Complete your profile with timezone and avatar."
      },
      %{
        number: "2",
        title: "Set Availability",
        description:
          "Configure business hours, breaks, and buffer times. Add calendar and video integrations."
      },
      %{
        number: "3",
        title: "Share Your Link",
        description:
          "Get your personalized #{domain}/username page with your branding and theme."
      },
      %{
        number: "4",
        title: "Start Scheduling",
        description: "Accept bookings, send automatic reminders, and join meetings with one click."
      }
    ]

    assigns = assign(assigns, steps: steps)

    ~H"""
    <section class="py-12 glass-content relative overflow-hidden">
      <div class="container mx-auto px-6">
        <h2 class="text-3xl md:text-4xl font-bold text-gray-800 text-center mb-3">
          How It Works
        </h2>
        <p class="text-lg text-gray-600 text-center mb-10 max-w-2xl mx-auto">
          Get started in minutes with our
          <span class="turquoise-accent font-semibold">4-step onboarding</span>
          process
        </p>
        <div class="grid md:grid-cols-2 lg:grid-cols-4 gap-6 max-w-5xl mx-auto relative">
          <.step_card :for={step <- @steps} {step} />
        </div>
      </div>
    </section>
    """
  end

  # Step card component
  defp step_card(assigns) do
    ~H"""
    <div class="relative group z-10">
      <div class="glass-card p-8 h-full hover-lift transition-all duration-300">
        <div class="flex items-start gap-4 mb-4">
          <div class="flex-shrink-0 w-16 h-16 rounded-full flex items-center justify-center shadow-lg bg-blue-600">
            <span class="text-2xl font-bold text-white">
              {@number}
            </span>
          </div>
          <h3 class="text-xl font-bold text-gray-800 pt-3">{@title}</h3>
        </div>
        <p class="text-base text-gray-600 leading-relaxed">{@description}</p>
      </div>
    </div>
    """
  end
end
