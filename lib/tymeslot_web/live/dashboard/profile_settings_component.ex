defmodule TymeslotWeb.Dashboard.ProfileSettingsComponent do
  @moduledoc """
  LiveView component for managing user profile settings including timezone,
  display name, scheduling preferences, and username configuration.

  This component acts as a container for specialized profile settings forms.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Profile.DeleteAvatarModal

  alias TymeslotWeb.Dashboard.ProfileSettings.{
    AvatarUploadComponent,
    DisplayNameFormComponent,
    TimeFormatFormComponent,
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
    <div>
      <.dashboard_page
        icon="hero-user"
        title={dgettext("dashboard_common", "Profile")}
        saving={@saving}
      >
        <.card class="relative overflow-hidden">
          <div class="relative z-10 grid grid-cols-1 lg:grid-cols-3 gap-12 items-start">
            <%!-- Avatar Section --%>
            <.live_component
              module={AvatarUploadComponent}
              id="avatar-upload"
              profile={@profile}
              current_user={@current_user}
            />

            <%!-- Settings Forms Section --%>
            <div class="lg:col-span-2 space-y-10 lg:border-l-2 lg:border-tymeslot-50 lg:pl-12 pt-4">
              <.subsection_header
                size={:lg}
                level={2}
                icon="hero-user"
                title={dgettext("dashboard_profile", "Basic Information")}
              />

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

                <div class="border-t-2 border-tymeslot-50 pt-10">
                  <.live_component
                    module={TimeFormatFormComponent}
                    id="time-format-form"
                    current_user={@current_user}
                  />
                </div>
              </div>
            </div>
          </div>
        </.card>

        <%!-- Delete Avatar Modal (rendered outside card to avoid z-index stacking issues) --%>
        <.live_component
          module={DeleteAvatarModal}
          id="delete-avatar-modal"
          profile={@profile}
        />
      </.dashboard_page>
    </div>
    """
  end
end
