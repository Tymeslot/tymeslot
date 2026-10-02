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
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.JitsiConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.KmeetConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.NextcloudTalkConfig
  alias TymeslotWeb.Dashboard.VideoSettings.Components
  alias TymeslotWeb.Live.Dashboard.VideoSettings.ProviderPicker

  @spec settings(map()) :: Phoenix.LiveView.Rendered.t()
  def settings(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <div class="flex items-center justify-between gap-4 flex-wrap">
        <.section_header
          icon="hero-video-camera"
          title={dgettext("dashboard_video", "Video Integration")}
        />
        <%!-- With nothing connected, the empty state below carries the action. --%>
        <.connect_button :if={@integrations != []} myself={@myself} />
      </div>

      <div>
        <%!-- Connected Video Providers Section --%>
        <%= if @integrations == [] do %>
          <.empty_state
            icon="hero-video-camera"
            size={:lg}
            data-testid="video-empty"
            title={dgettext("dashboard_video", "No video providers connected yet")}
            description={
              dgettext(
                "dashboard_video",
                "Connect one so online meetings get a video link added automatically when they're booked."
              )
            }
          >
            <:action><.connect_button myself={@myself} /></:action>
          </.empty_state>
        <% else %>
          <% {active_integrations, inactive_integrations} =
            Enum.split_with(@integrations, & &1.is_active) %>
          <% show_section_headers = active_integrations != [] and inactive_integrations != [] %>

          <div class="space-y-6">
            <%!-- Active Video Integrations --%>
            <%= if active_integrations != [] do %>
              <div class="space-y-3">
                <%= if show_section_headers do %>
                  <h3 class="text-lg font-bold text-turquoise-800">
                    {dgettext("dashboard_video", "Active Video Integrations")}
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
                    {dgettext("dashboard_video", "Inactive Video Integrations")}
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
          title={dgettext("dashboard_video", "Connect a video provider")}
          subtitle={
            dgettext(
              "dashboard_video",
              "Add a video link to online meetings automatically when they're booked."
            )
          }
          target={@myself}
          on_cancel={JS.push("hide_picker", target: @myself)}
          groups={ProviderPicker.groups(@available_video_providers, @integrations)}
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
            <.live_component
              :if={@config_provider == "kmeet"}
              module={KmeetConfig}
              id="kmeet-config"
              target={@myself}
              form_errors={@form_errors}
              form_values={@form_values}
              saving={@saving}
            />
            <.live_component
              :if={@config_provider == "jitsi"}
              module={JitsiConfig}
              id="jitsi-config"
              target={@myself}
              form_errors={@form_errors}
              form_values={@form_values}
              saving={@saving}
            />
            <.live_component
              :if={@config_provider == "nextcloud_talk"}
              module={NextcloudTalkConfig}
              id="nextcloud-talk-config"
              target={@myself}
              form_errors={@form_errors}
              form_values={@form_values}
              saving={@saving}
              nextcloud_calendars={@nextcloud_calendars}
              copied_login={@copied_nextcloud_login}
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

  attr :myself, :any, required: true

  defp connect_button(assigns) do
    ~H"""
    <button
      phx-click="show_picker"
      phx-target={@myself}
      class="inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-500 px-4 py-2 text-token-sm font-semibold text-white transition-colors hover:bg-turquoise-600 shrink-0"
    >
      <.icon name="hero-plus" class="w-4 h-4" />
      {dgettext("dashboard_video", "Connect a video provider")}
    </button>
    """
  end
end
