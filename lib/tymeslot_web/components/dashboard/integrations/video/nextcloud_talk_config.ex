defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.NextcloudTalkConfig do
  @moduledoc """
  Component for configuring the Nextcloud Talk video integration.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Icons.ProviderIcon

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form_values, %{})
     |> assign(:form_errors, %{})
     |> assign(:saving, false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form_values, fn -> %{} end)
     |> assign_new(:form_errors, fn -> %{} end)
     |> assign_new(:saving, fn -> false end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="nextcloud-talk-config-modal" class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="nextcloud_talk" type="video" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">Nextcloud Talk</h3>
          <p class="text-sm text-tymeslot-500 font-medium">
            {dgettext("dashboard_integrations", "Video meetings on your own Nextcloud")}
          </p>
        </div>
      </div>

      <form
        id="nextcloud-talk-integration-form"
        phx-submit="add_integration"
        phx-change="track_form_change"
        phx-target={@target}
        class="space-y-5"
      >
        <input type="hidden" name="integration[provider]" value="nextcloud_talk" />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            value={
              Map.get(@form_values, "name", dgettext("dashboard_integrations", "My Nextcloud Talk"))
            }
            target={@target}
          />

          <SharedForm.url_field
            id="nextcloud_talk_base_url"
            name="integration[base_url]"
            label={dgettext("dashboard_integrations", "Server URL")}
            value={Map.get(@form_values, "base_url", "")}
            placeholder={dgettext("dashboard_integrations", "https://cloud.yourdomain.com")}
            form_errors={@form_errors}
            error_key={:base_url}
            target={@target}
            helper_text={
              dgettext(
                "dashboard_integrations",
                "The address you open Nextcloud at, including any subpath"
              )
            }
          />

          <SharedForm.username_field
            id="nextcloud_talk_username"
            name="integration[username]"
            value={Map.get(@form_values, "username", "")}
            placeholder={dgettext("dashboard_integrations", "Your Nextcloud username")}
            form_errors={@form_errors}
            target={@target}
          />

          <SharedForm.api_key_field
            id="nextcloud_talk_app_password"
            name="integration[api_key]"
            label={dgettext("dashboard_integrations", "App Password")}
            value={Map.get(@form_values, "api_key", "")}
            placeholder={dgettext("dashboard_integrations", "xxxxx-xxxxx-xxxxx-xxxxx-xxxxx")}
            form_errors={@form_errors}
            target={@target}
            helper_text={
              dgettext(
                "dashboard_integrations",
                "Create one in Nextcloud under Personal settings → Security → Devices & sessions"
              )
            }
          />
        </div>

        <p class="text-xs text-tymeslot-500">
          {dgettext(
            "dashboard_integrations",
            "Each booking gets its own public Talk conversation. Guests can chat and join calls, but only you can start a call."
          )}
        </p>

        <%= if error = SharedForm.form_level_error(@form_errors) do %>
          <SharedForm.error_banner error={error} />
        <% end %>

        <div class="flex justify-between items-center pt-4 border-t border-tymeslot-100">
          <button
            type="button"
            phx-click="back_to_providers"
            phx-target={@target}
            class="btn-secondary"
          >
            {dgettext("dashboard_integrations", "Cancel")}
          </button>
          <TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents.form_submit_button saving={
            @saving
          } />
        </div>
      </form>
    </div>
    """
  end
end
