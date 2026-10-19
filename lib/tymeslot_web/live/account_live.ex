defmodule TymeslotWeb.AccountLive do
  @moduledoc """
  LiveView for managing account security settings.
  Handles email and password changes with modular component architecture.
  """
  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Locales
  alias TymeslotWeb.AccountLive.{DangerZone, DeleteAccountModal, Handlers, Helpers}

  import TymeslotWeb.AccountLive.Components

  @impl Phoenix.LiveView
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, dgettext("account", "Account Settings"))
     |> assign(:supported_locales, Locales.supported())
     # Lets a deletion request end every session but leave this socket
     # connected long enough to deliver its own redirect.
     |> assign(:session_token, session["user_token"])
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
            <.action_link
              navigate={~p"/dashboard"}
              variant={:secondary}
              size={:sm}
              icon="hero-arrow-left"
              aria-label={dgettext("account", "Back to Dashboard")}
            >
              <span class="hidden sm:inline">{dgettext("account", "Back to Dashboard")}</span>
            </.action_link>

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
              <.language_card current_user={@current_user} supported_locales={@supported_locales} />
              <DangerZone.danger_zone_card grace_days={@deletion_grace_days} />
            </div>
          </div>
        </main>
      </div>

      <DeleteAccountModal.delete_account_modal
        :if={@show_delete_modal}
        confirmation={@deletion_confirmation}
        grace_days={@deletion_grace_days}
        deletion_date={@deletion_date}
        feedback_options={@deletion_feedback_options}
        errors={@delete_errors}
      />
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
