defmodule TymeslotWeb.AccountLive do
  @moduledoc """
  LiveView for managing account security settings.
  Handles email and password changes with modular component architecture.
  """
  use TymeslotWeb, :live_view

  alias TymeslotWeb.AccountLive.{Handlers, Helpers}

  import TymeslotWeb.AccountLive.Components

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Account Settings")
     |> Helpers.init_form_state()}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="min-h-screen">
      <%!-- Simple header with back button --%>
      <nav class="brand-nav mb-6 relative" style="z-index: 50;">
        <div class="container mx-auto px-4">
          <div class="flex items-center justify-between h-16">
            <%!-- Back to Dashboard button --%>
            <.link
              patch={~p"/dashboard"}
              class="inline-flex items-center space-x-2 btn-secondary text-sm px-4 py-2"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
              <span>Back to Dashboard</span>
            </.link>
            
    <%!-- User dropdown --%>
            <div class="relative">
              <.live_component
                module={TymeslotWeb.Components.UserDropdownComponent}
                id="user-dropdown"
                current_user={@current_user}
                profile={@profile}
              />
            </div>
          </div>
        </div>
      </nav>
      
    <%!-- Account content --%>
      <div class="container mx-auto px-4 py-8">
        <main>
          <div class="max-w-6xl mx-auto">
            <.security_header />

            <div class="space-y-6">
              <.email_card {assigns} />
              <.password_card {assigns} />
            </div>
          </div>
        </main>
      </div>
    </div>
    """
  end

  # Delegate all events to handler module
  @impl Phoenix.LiveView
  def handle_event(event, params, socket) do
    Handlers.handle_event(event, params, socket)
  end

  # Handle events from child components
  @impl Phoenix.LiveView
  def handle_info({:flash, {type, message}}, socket) do
    {:noreply, put_flash(socket, type, message)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end
end
