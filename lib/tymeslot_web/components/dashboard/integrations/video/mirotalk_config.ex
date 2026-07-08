defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig do
  @moduledoc """
  Component for configuring MiroTalk P2P video integration.
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
    <div id="mirotalk-config-modal" class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="mirotalk" type="video" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">MiroTalk P2P</h3>
          <p class="text-sm text-tymeslot-500 font-medium">
            {dgettext("dashboard_integrations", "Self-hosted video conferencing")}
          </p>
        </div>
      </div>

      <form id="mirotalk-integration-form" phx-submit="add_integration" phx-change="track_form_change" phx-target={@target} class="space-y-5">
        <input type="hidden" name="integration[provider]" value="mirotalk" />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            value={Map.get(@form_values, "name", "My MiroTalk")}
            target={@target}
          />

          <SharedForm.url_field
            id="mirotalk_base_url"
            name="integration[base_url]"
            label={dgettext("dashboard_integrations", "Server URL")}
            value={Map.get(@form_values, "base_url", "")}
            placeholder="https://mirotalk.yourdomain.com"
            form_errors={@form_errors}
            error_key={:base_url}
            target={@target}
            helper_text={
              dgettext(
                "dashboard_integrations",
                "The full URL where your MiroTalk P2P instance is hosted"
              )
            }
          />

          <div class="md:col-span-2">
            <SharedForm.api_key_field
              id="mirotalk_api_key"
              name="integration[api_key]"
              value={Map.get(@form_values, "api_key", "")}
              placeholder="your-api-key-here"
              form_errors={@form_errors}
              target={@target}
              helper_text={
                dgettext(
                  "dashboard_integrations",
                  "Get your API key from your MiroTalk instance configuration"
                )
              }
            />
          </div>
        </div>

        <div class="flex justify-between items-center pt-4 border-t border-tymeslot-100">
          <button type="button" phx-click="back_to_providers" phx-target={@target} class="btn-secondary">
            {dgettext("dashboard_integrations", "Cancel")}
          </button>
          <TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents.form_submit_button saving={@saving} />
        </div>
      </form>
    </div>
    """
  end
end
