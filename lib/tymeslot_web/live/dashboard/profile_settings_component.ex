defmodule TymeslotWeb.Dashboard.ProfileSettingsComponent do
  @moduledoc """
  LiveView component for managing user profile settings including timezone,
  display name, scheduling preferences, and username configuration.

  This component acts as a container for specialized profile settings forms.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.Dashboard.Profile.DeleteAvatarModal

  alias TymeslotWeb.Dashboard.ProfileSettings.{
    AvatarUploadComponent,
    DisplayNameFormComponent,
    TimezoneFormComponent,
    UsernameFormComponent
  }

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, assign(socket, saving: false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <CoreComponents.section_header icon={:user} title="Profile Settings" saving={@saving} />

      <div class="max-w-5xl mx-auto">
        <div class="card-glass relative overflow-hidden">
          <div class="relative z-10 grid grid-cols-1 lg:grid-cols-3 gap-12 items-start">
            <!-- Avatar Section -->
            <.live_component
              module={AvatarUploadComponent}
              id="avatar-upload"
              profile={@profile}
              current_user={@current_user}
            />

            <!-- Settings Forms Section -->
            <div class="lg:col-span-2 space-y-10 lg:border-l-2 lg:border-tymeslot-50 lg:pl-12 pt-4">
              <div class="flex items-center gap-4 mb-2">
                <div class="w-12 h-12 bg-cyan-50 rounded-token-xl flex items-center justify-center border border-cyan-100 shadow-sm">
                  <svg class="w-6 h-6 text-cyan-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2.5"
                      d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
                    />
                  </svg>
                </div>
                <h3 class="text-2xl font-black text-tymeslot-900 tracking-tight">Basic Information</h3>
              </div>

              <div class="space-y-10">
                <.live_component
                  module={DisplayNameFormComponent}
                  id="display-name-form"
                  profile={@profile}
                />

                <div class="border-t-2 border-tymeslot-50 pt-10">
                  <.live_component
                    module={UsernameFormComponent}
                    id="username-form"
                    profile={@profile}
                    current_user={@current_user}
                  />
                </div>

                <div class="border-t-2 border-tymeslot-50 pt-10">
                  <.live_component
                    module={TimezoneFormComponent}
                    id="timezone-form"
                    profile={@profile}
                  />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Delete Avatar Modal (rendered outside card to avoid z-index stacking issues) -->
      <.live_component
        module={DeleteAvatarModal}
        id="delete-avatar-modal"
        profile={@profile}
      />
    </div>
    """
  end
end
