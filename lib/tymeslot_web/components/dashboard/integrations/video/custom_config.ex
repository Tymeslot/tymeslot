defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig do
  @moduledoc """
  Component for configuring custom video integration setup.
  """
  use TymeslotWeb, :live_component

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
          <h3 class="text-xl font-black text-tymeslot-900 tracking-tight">Custom Video Link</h3>
          <p class="text-sm text-tymeslot-500 font-medium">Connect any video platform</p>
        </div>
      </div>

      <form id="custom-video-integration-form" phx-submit="add_integration" phx-change="track_form_change" phx-target={@target} class="space-y-5">
        <input type="hidden" name="integration[provider]" value="custom" />

        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            value={Map.get(@form_values, "name", "My Custom Video")}
            target={@target}
          />

          <div class="space-y-3">
            <SharedForm.url_field
              id="custom_meeting_url"
              name="integration[custom_meeting_url]"
              label="Meeting URL"
              value={Map.get(@form_values, "custom_meeting_url", "")}
              placeholder="https://jitsi.example.org/{{meeting_id}}"
              form_errors={@form_errors}
              error_key={:custom_meeting_url}
              target={@target}
              helper_text="Enter your video meeting URL. Use {{meeting_id}} for unique rooms per meeting"
            />

            <%= case TemplateAnalyzer.analyze(Map.get(@form_values, "custom_meeting_url", "")) do %>
              <% {:ok, :valid_template, preview, _message} -> %>
                <TemplatePreviewBox.render
                  status={:valid}
                  title="✓ Valid Template"
                  message="Template variable detected: {{meeting_id}}"
                  preview={preview}
                />

              <% {:warning, _type, preview, error_message} -> %>
                <TemplatePreviewBox.render
                  status={:warning}
                  title="⚠ Invalid Syntax"
                  message={error_message}
                  preview={preview}
                />

              <% {:ok, :static, _url, _message} -> %>
                <TemplatePreviewBox.render
                  status={:static}
                  title="Static Meeting Room"
                  message="All meetings will use the same room URL"
                />

              <% {:ok, :empty, _url, _message} -> %>
                <TemplatePreviewBox.render
                  status={:empty}
                  title="No URL Configured"
                  message="Enter a custom video link to configure meeting rooms"
                />
            <% end %>
          </div>
        </div>

        <%= if error = SharedForm.form_level_error(@form_errors) do %>
          <SharedForm.error_banner error={error} />
        <% end %>

        <div class="flex justify-between items-center pt-4 border-t border-tymeslot-100">
          <button type="button" phx-click="back_to_providers" phx-target={@target} class="btn-secondary">
            Cancel
          </button>
          <TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents.form_submit_button saving={@saving} />
        </div>
      </form>
    </div>
    """
  end
end
