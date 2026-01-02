defmodule TymeslotWeb.HomepageLive.CTASection do
  use TymeslotWeb, :live_component

  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <section class="py-16 container mx-auto px-6 text-center">
      <div class="glass-card p-12 max-w-3xl mx-auto">
        <h2 class="text-3xl md:text-4xl font-bold text-gray-800 mb-4">
          Ready to <span class="turquoise-accent">Simplify</span> Your Scheduling?
        </h2>
        <p class="text-xl text-gray-600 mb-8">
          Join professionals who save hours every week with automated scheduling.
        </p>
        <%= if @current_user do %>
          <.link
            navigate={~p"/dashboard"}
            class="glass-button text-lg px-8 py-4 hover-grow inline-block"
          >
            Go to Your Dashboard
          </.link>
        <% else %>
          <.link
            navigate={~p"/auth/signup"}
            class="glass-button text-lg px-8 py-4 hover-grow inline-block"
          >
            Get Started Free
          </.link>
        <% end %>
      </div>
    </section>
    """
  end
end
