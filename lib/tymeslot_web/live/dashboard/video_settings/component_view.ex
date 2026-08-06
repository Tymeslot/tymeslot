defmodule TymeslotWeb.Dashboard.VideoSettings.ComponentView do
  @moduledoc """
  Markup for the video integrations settings component.

  Extracted from `VideoSettingsComponent` so that module stays focused on lifecycle
  and event routing, matching how `CalendarSettings.ComponentView` sits behind
  `CalendarSettingsComponent`. `settings/1` receives the component's assigns
  unchanged (its `render/1` delegates straight to it), so LiveView change
  tracking is preserved.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.DeleteIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.ProviderPickerModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.EditVideoIntegrationModal
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig
  alias TymeslotWeb.Dashboard.VideoSettings.Components

  def settings(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <.section_header
          icon="hero-video-camera"
          title={dgettext("dashboard_integrations", "Video Integration")}
        />
        <button
          phx-click="show_picker"
          phx-target={@myself}
          class="inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-4 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600 shrink-0"
        >
          <.icon name="hero-plus" class="w-4 h-4" />
          {dgettext("dashboard_integrations", "Connect a video provider")}
        </button>
      </div>

      <div>
        <%!-- Connected Video Providers Section --%>
        <%= if @integrations == [] do %>
          <div class="card-glass p-10 text-center">
            <div class="mx-auto mb-4 flex h-14 w-14 items-center justify-center rounded-token-2xl bg-turquoise-50 text-turquoise-500">
              <.icon name="hero-video-camera" class="h-7 w-7" />
            </div>
            <h3 class="text-token-lg font-semibold text-tymeslot-800">
              {dgettext("dashboard_integrations", "No video providers connected yet")}
            </h3>
            <p class="mx-auto mt-1 max-w-md text-token-sm text-tymeslot-500">
              {dgettext(
                "dashboard_integrations",
                "Connect one so online meetings get a video link added automatically when they're booked."
              )}
            </p>
            <button
              phx-click="show_picker"
              phx-target={@myself}
              class="mt-5 inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-4 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600"
            >
              <.icon name="hero-plus" class="w-4 h-4" />
              {dgettext("dashboard_integrations", "Connect a video provider")}
            </button>
          </div>
        <% else %>
          <% {active_integrations, inactive_integrations} = Enum.split_with(@integrations, & &1.is_active) %>
          <% show_section_headers = active_integrations != [] and inactive_integrations != [] %>

          <div class="space-y-6">
            <%!-- Active Video Integrations --%>
            <%= if active_integrations != [] do %>
              <div class="space-y-3">
                <%= if show_section_headers do %>
                  <h3 class="text-lg font-bold text-turquoise-800">
                    {dgettext("dashboard_integrations", "Active Video Integrations")}
                  </h3>
                <% end %>

                <%= for integration <- active_integrations do %>
                  <Components.video_connection_row
                    integration={integration}
                    testing_connection={@testing_connection}
                    myself={@myself}
                    health_state={Map.get(@health_states, integration.id)}
                  />
                <% end %>
              </div>
            <% end %>

            <%!-- Inactive Video Integrations --%>
            <%= if inactive_integrations != [] do %>
              <div class="space-y-3">
                <%= if show_section_headers do %>
                  <h3 class="text-lg font-semibold text-tymeslot-600">
                    {dgettext("dashboard_integrations", "Inactive Video Integrations")}
                  </h3>
                <% end %>

                <%= for integration <- inactive_integrations do %>
                  <Components.video_connection_row
                    integration={integration}
                    testing_connection={@testing_connection}
                    myself={@myself}
                    health_state={Map.get(@health_states, integration.id)}
                  />
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <ProviderPickerModal.provider_picker_modal
          id="video-provider-picker"
          show={@show_picker}
          title={dgettext("dashboard_integrations", "Connect a video provider")}
          subtitle={
            dgettext(
              "dashboard_integrations",
              "Add a video link to online meetings automatically when they're booked."
            )
          }
          target={@myself}
          on_cancel={JS.push("hide_picker", target: @myself)}
          groups={picker_groups(@available_video_providers, @integrations)}
          config_active={@config_provider != nil}
          back_event="back_to_providers"
        >
          <:config>
            <.live_component
              :if={@config_provider == "mirotalk"}
              module={MirotalkConfig}
              id="mirotalk-config"
              target={@myself}
              form_errors={@form_errors}
              form_values={@form_values}
              saving={@saving}
            />
            <.live_component
              :if={@config_provider == "custom"}
              module={CustomConfig}
              id="custom-config"
              target={@myself}
              form_errors={@form_errors}
              form_values={@form_values}
              saving={@saving}
            />
          </:config>
        </ProviderPickerModal.provider_picker_modal>
      </div>

      <%!-- Edit Integration Modal --%>
      <.live_component
        module={EditVideoIntegrationModal}
        id="edit-video-modal"
        integrations={@integrations}
        current_user={@current_user}
      />

      <%!-- Delete Confirmation Modal --%>
      <.live_component
        module={DeleteIntegrationModal}
        id="delete-video-modal"
        integration_type={:video}
        current_user={@current_user}
      />
    </div>
    """
  end

  # Builds the single-group provider list for the picker modal.
  defp picker_groups(available, integrations) do
    entries = Enum.map(available, &provider_entry(&1, integrations))
    [%{label: nil, providers: entries}]
  end

  defp provider_entry(descriptor, integrations) do
    provider = Atom.to_string(descriptor.type)

    %{
      provider: provider,
      title: descriptor.display_name,
      description: descriptor.description,
      click_event: "setup_provider",
      connected?: Enum.any?(integrations, &(&1.provider == provider))
    }
  end
end
