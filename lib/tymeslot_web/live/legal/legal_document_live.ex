defmodule TymeslotWeb.Legal.LegalDocumentLive do
  use TymeslotWeb, :live_view

  alias Tymeslot.Deployment
  alias TymeslotWeb.Components.SiteComponents
  alias TymeslotWeb.Legal.PrivacyPolicyComponent
  alias TymeslotWeb.Legal.TermsAndConditionsComponent
  alias TymeslotWeb.Live.Shared.LiveHelpers

  @impl true
  def mount(%{"document_type" => document_type}, session, socket) do
    socket =
      case document_type do
        "privacy-policy" ->
          assign(socket, :document_type, :privacy_policy)

        "terms-and-conditions" ->
          assign(socket, :document_type, :terms_and_conditions)

        _ ->
          socket |> put_flash(:error, "Document not found") |> redirect(to: "/")
      end

    socket = LiveHelpers.assign_current_user(socket, session)
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gradient-to-br from-gray-50 via-white to-gray-100">
      <!-- Navigation -->
      <SiteComponents.navigation current_user={@current_user} />
      
    <!-- Legal Document Content -->
      <div class="container mx-auto px-6 py-16">
        <div class="max-w-4xl mx-auto">
          <!-- Back to Home Button -->
          <div class="mb-8">
            <.link
              navigate={home_link(@current_user)}
              class="glass-button text-lg px-8 py-4 hover-grow inline-flex items-center"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5 mr-2"
                viewBox="0 0 20 20"
                fill="currentColor"
              >
                <path
                  fill-rule="evenodd"
                  d="M9.707 16.707a1 1 0 01-1.414 0l-6-6a1 1 0 010-1.414l6-6a1 1 0 011.414 1.414L5.414 9H17a1 1 0 110 2H5.414l4.293 4.293a1 1 0 010 1.414z"
                  clip-rule="evenodd"
                />
              </svg>
              Back to Home
            </.link>
          </div>

          <div class="glass-card p-8 md:p-12">
            <%= case @document_type do %>
              <% :privacy_policy -> %>
                <.live_component module={PrivacyPolicyComponent} id="privacy-policy" />
              <% :terms_and_conditions -> %>
                <.live_component module={TermsAndConditionsComponent} id="terms-and-conditions" />
            <% end %>
          </div>
        </div>
      </div>
      
    <!-- Footer -->
      <SiteComponents.site_footer />
    </div>
    """
  end

  # Private helper function to determine home link destination
  defp home_link(current_user) do
    cond do
      # If user is logged in, go to dashboard
      current_user -> ~p"/dashboard"
      # If main deployment, go to homepage
      Deployment.main?() -> ~p"/"
      # If self-hosted, go to login
      true -> ~p"/auth/login"
    end
  end
end
