defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig do
  @moduledoc """
  Component for configuring custom video integration setup.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplateAnalyzer
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplatePreviewBox

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
    <div id="custom-video-config-modal" class="space-y-6">
      <div class="flex items-center gap-4 mb-2">
        <ProviderIcon.provider_icon provider="custom" type="video" size="large" />
        <div>
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_integrations", "Custom Video Link")}
          </h3>
          <p class="text-sm text-tymeslot-500 font-medium">
            {dgettext("dashboard_integrations", "Connect any video platform")}
          </p>
        </div>
      </div>

      <form id="custom-video-integration-form" phx-submit="add_integration" phx-change="track_form_change" phx-target={@target} class="space-y-5">
        <input type="hidden" name="integration[provider]" value="custom" />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            value={Map.get(@form_values, "name", dgettext("dashboard_integrations", "My Custom Video"))}
            target={@target}
          />

          <div class="space-y-3">
            <SharedForm.url_field
              id="custom_meeting_url"
              name="integration[custom_meeting_url]"
              label={dgettext("dashboard_integrations", "Meeting URL")}
              value={Map.get(@form_values, "custom_meeting_url", "")}
              placeholder="https://jitsi.example.org/{{meeting_id}}"
              form_errors={@form_errors}
              error_key={:custom_meeting_url}
              target={@target}
              helper_text={
                dgettext(
                  "dashboard_integrations",
                  "Enter your video meeting URL. Use {{meeting_id}} for unique rooms per meeting"
                )
              }
            />

            <%= case TemplateAnalyzer.analyze(Map.get(@form_values, "custom_meeting_url", "")) do %>
              <% {:ok, :valid_template, preview, _message} -> %>
                <TemplatePreviewBox.render
                  status={:valid}
                  title={dgettext("dashboard_integrations", "✓ Valid Template")}
                  message={
                    dgettext("dashboard_integrations", "Template variable detected: {{meeting_id}}")
                  }
                  preview={preview}
                />

              <% {:warning, _type, preview, error_message} -> %>
                <TemplatePreviewBox.render
                  status={:warning}
                  title={dgettext("dashboard_integrations", "⚠ Invalid Syntax")}
                  message={error_message}
                  preview={preview}
                />

              <% {:ok, :static, _url, _message} -> %>
                <TemplatePreviewBox.render
                  status={:static}
                  title={dgettext("dashboard_integrations", "Static Meeting Room")}
                  message={
                    dgettext("dashboard_integrations", "All meetings will use the same room URL")
                  }
                />

              <% {:ok, :empty, _url, _message} -> %>
                <TemplatePreviewBox.render
                  status={:empty}
                  title={dgettext("dashboard_integrations", "No URL Configured")}
                  message={
                    dgettext(
                      "dashboard_integrations",
                      "Enter a custom video link to configure meeting rooms"
                    )
                  }
                />
            <% end %>
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
