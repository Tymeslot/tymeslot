defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.EditVideoIntegrationModal do
  @moduledoc """
  Modal for editing an existing video integration.
  Manages its own show/hide state, following the DeleteIntegrationModal pattern.
  """

  use TymeslotWeb, :live_component

  require Logger

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.InputValidation, as: VideoInputValidation
  alias Tymeslot.Utils.SanitizeMerge
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplateAnalyzer
  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplatePreviewBox

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Dashboard.VideoSettingsComponent
  alias TymeslotWeb.Live.Dashboard.Shared.DashboardHelpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok,
     socket
     |> assign(:show, false)
     |> assign(:integration, nil)
     |> assign(:form_values, %{})
     |> assign(:form_errors, %{})
     |> assign(:saving, false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("show", %{"id" => id}, socket) do
    case parse_integration_id(id) do
      {:ok, integration_id} ->
        case find_integration(socket.assigns.integrations, integration_id) do
          nil ->
            {:noreply, socket}

          integration ->
            form_values = build_form_values(integration)

            {:noreply,
             socket
             |> assign(:show, true)
             |> assign(:integration, integration)
             |> assign(:form_values, form_values)
             |> assign(:form_errors, %{})
             |> assign(:saving, false)}
        end

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("hide", _params, socket) do
    {:noreply,
     socket
     |> assign(:show, false)
     |> assign(:integration, nil)
     |> assign(:form_values, %{})
     |> assign(:form_errors, %{})
     |> assign(:saving, false)}
  end

  def handle_event("track_form_change", %{"integration" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  def handle_event("validate_field", %{"field" => field, "value" => value}, socket) do
    field_atom = map_field_to_atom(field)

    if String.trim(to_string(value)) == "" do
      current_errors = socket.assigns.form_errors

      {:noreply,
       assign(
         socket,
         :form_errors,
         FormValidationHelpers.delete_field_error(current_errors, field_atom)
       )}
    else
      case VideoInputValidation.validate_single_field(field_atom, value,
             metadata: DashboardHelpers.get_security_metadata(socket)
           ) do
        {:ok, _sanitized} ->
          {:noreply,
           assign(
             socket,
             :form_errors,
             FormValidationHelpers.delete_field_error(socket.assigns.form_errors, field_atom)
           )}

        {:error, error} ->
          {:noreply,
           assign(socket, :form_errors, Map.put(socket.assigns.form_errors, field_atom, error))}
      end
    end
  end

  def handle_event("save", %{"integration" => params}, socket) do
    integration = socket.assigns.integration
    user_id = socket.assigns.current_user.id

    params_with_provider = Map.put(params, "provider", integration.provider)

    case VideoInputValidation.validate_video_integration_form(params_with_provider,
           metadata: DashboardHelpers.get_security_metadata(socket)
         ) do
      {:ok, sanitized} ->
        attrs = map_keys_to_atoms(SanitizeMerge.merge(params, sanitized))

        case Video.update_integration(user_id, integration.id, attrs) do
          {:ok, _updated} ->
            send(self(), {:flash, {:info, "Integration updated successfully"}})
            send_update(VideoSettingsComponent, id: "video")

            {:noreply,
             socket
             |> assign(:show, false)
             |> assign(:integration, nil)
             |> assign(:saving, false)}

          {:error, _reason} ->
            send(self(), {:flash, {:error, "Failed to update integration"}})
            {:noreply, assign(socket, :saving, false)}
        end

      {:error, validation_errors} ->
        {:noreply,
         socket
         |> assign(:form_errors, validation_errors)
         |> assign(:form_values, params)}
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <TymeslotWeb.Components.CoreComponents.modal
        id={"#{@id}-modal"}
        show={@show}
        on_cancel={JS.push("hide", target: @myself)}
        size={:medium}
      >
        <:header>
          <div class="flex items-center gap-2">
            <.icon name="hero-pencil-square" class="w-5 h-5 text-turquoise-600" />
            Edit Integration
          </div>
        </:header>

        <%= if @integration do %>
          <form
            id="edit-video-integration-form"
            phx-submit="save"
            phx-change="track_form_change"
            phx-target={@myself}
            class="space-y-5"
          >
            <input type="hidden" name="integration[provider]" value={@integration.provider} />

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <SharedForm.integration_name_field
                form_errors={@form_errors}
                value={Map.get(@form_values, "name", @integration.name || "")}
                target={@myself}
              />

              <%= case @integration.provider do %>
                <% "custom" -> %>
                  <SharedForm.url_field
                    id="edit_custom_meeting_url"
                    name="integration[custom_meeting_url]"
                    label="Meeting URL"
                    value={Map.get(@form_values, "custom_meeting_url", @integration.custom_meeting_url || "")}
                    placeholder="https://jitsi.example.org/{{meeting_id}}"
                    form_errors={@form_errors}
                    error_key={:custom_meeting_url}
                    target={@myself}
                    helper_text="Enter your video meeting URL. Use {{meeting_id}} for unique rooms per meeting"
                  />

                <% "mirotalk" -> %>
                  <SharedForm.url_field
                    id="edit_base_url"
                    name="integration[base_url]"
                    label="Base URL"
                    value={Map.get(@form_values, "base_url", @integration.base_url || "")}
                    placeholder="https://mirotalk.example.com"
                    form_errors={@form_errors}
                    error_key={:base_url}
                    target={@myself}
                    helper_text="Your MiroTalk instance base URL"
                  />

                  <div class="md:col-span-2">
                    <SharedForm.api_key_field
                      id="edit_api_key"
                      name="integration[api_key]"
                      form_errors={@form_errors}
                      value={Map.get(@form_values, "api_key", "")}
                      placeholder="Enter new API key"
                      target={@myself}
                    />
                  </div>

                <% _ -> %>
              <% end %>
            </div>

            <%= if @integration.provider == "custom" do %>
              <% url_value = Map.get(@form_values, "custom_meeting_url", @integration.custom_meeting_url || "") %>
              <%= case TemplateAnalyzer.analyze(url_value) do %>
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
            <% end %>

            <div class="flex justify-end gap-3 pt-4 border-t border-tymeslot-100">
              <button
                type="button"
                phx-click={JS.push("hide", target: @myself)}
                class="btn btn-secondary"
              >
                Cancel
              </button>

              <TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents.form_submit_button
                saving={@saving}
                text="Save Changes"
                saving_text="Saving..."
              />
            </div>
          </form>
        <% end %>
      </TymeslotWeb.Components.CoreComponents.modal>
    </div>
    """
  end

  # Private helpers

  defp find_integration(integrations, id) do
    Enum.find(integrations, &(&1.id == id))
  end

  defp build_form_values(integration) do
    base = %{"name" => integration.name || ""}

    case integration.provider do
      "custom" ->
        Map.put(base, "custom_meeting_url", integration.custom_meeting_url || "")

      "mirotalk" ->
        base
        |> Map.put("base_url", integration.base_url || "")
        |> Map.put("api_key", "")

      _oauth ->
        base
    end
  end

  defp parse_integration_id(id) when is_integer(id), do: {:ok, id}

  defp parse_integration_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} when int > 0 -> {:ok, int}
      _other -> {:error, :invalid}
    end
  end

  defp parse_integration_id(_arg), do: {:error, :invalid_type}

  defp map_field_to_atom("name"), do: :name
  defp map_field_to_atom("base_url"), do: :base_url
  defp map_field_to_atom("api_key"), do: :api_key
  defp map_field_to_atom("custom_meeting_url"), do: :custom_meeting_url
  defp map_field_to_atom(_other), do: :unknown

  defp map_keys_to_atoms(map) do
    for {k, v} <- map, into: %{} do
      key =
        if is_binary(k) do
          try do
            String.to_existing_atom(k)
          rescue
            ArgumentError ->
              # Debug rather than warning: the keys come straight from a form
              # post, so anyone could otherwise fill the log with unknown ones.
              Logger.debug("Leaving unknown form key as a string", form_key: k)

              k
          end
        else
          k
        end

      {key, v}
    end
  end
end
