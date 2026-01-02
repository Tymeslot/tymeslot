defmodule TymeslotWeb.Dashboard.ServiceSettingsComponent do
  @moduledoc """
  LiveComponent for managing meeting settings in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Security.MeetingSettingsInputProcessor
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal
  alias TymeslotWeb.Components.DashboardComponents
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent
  alias TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash
  import TymeslotWeb.Components.UI.CloseButton
  require Logger

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:meeting_types, [])
     |> assign(:show_add_form, false)
     |> assign(:editing_type, nil)
     |> assign(:show_edit_overlay, false)
     |> assign(:form_errors, %{})
     |> assign(:saving, false)
     |> assign(:video_integrations, [])
     |> ModalHook.mount_modal(delete_meeting_type: false)}
  end

  @impl true
  def update(assigns, socket) do
    # Always ensure we have the latest profile data
    socket =
      socket
      |> assign(assigns)
      |> Helpers.maybe_reload_profile()

    # Load meeting settings data directly (own your data)
    user_id = assigns.current_user.id
    data = DashboardContext.get_meeting_settings_data(user_id)

    socket =
      socket
      |> assign(:meeting_types, sort_meeting_types(data.meeting_types))
      |> assign(:video_integrations, data.video_integrations)

    {:ok, socket}
  end

  # --- Sorting helpers ---
  defp sort_meeting_types(types) when is_list(types) do
    Enum.sort_by(types, fn type -> sort_key_for_type(type) end)
  end

  defp sort_key_for_type(%{name: name}) do
    name = String.trim(name || "")

    case Regex.run(~r/\d+/, name) do
      [num_str] ->
        # Numeric-first ordering, then by full name for stability
        {0, String.to_integer(num_str), String.downcase(name)}

      _ ->
        # Alphabetical ordering fallback
        {1, nil, String.downcase(name)}
    end
  end

  defp sort_key_for_type(_), do: {1, nil, ""}

  @impl true
  def handle_event("toggle_add_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_form, !socket.assigns.show_add_form)
     |> assign(:editing_type, nil)
     |> assign(:form_errors, %{})
     |> assign(:selected_icon, "none")
     |> assign(:form_data, %{})}
  end

  def handle_event("edit_type", %{"id" => id}, socket) do
    type = Enum.find(socket.assigns.meeting_types, &(&1.id == String.to_integer(id)))

    if is_nil(type) do
      Flash.error("Meeting type not found")
      {:noreply, socket}
    else
      form_data = %{
        "name" => type.name || "",
        "duration" => to_string(type.duration_minutes || 30),
        "description" => type.description || "",
        "icon" => type.icon || "none"
      }

      socket =
        socket
        |> assign(:editing_type, type)
        |> assign(:show_add_form, false)
        |> assign(:show_edit_overlay, true)
        |> assign(:form_errors, %{})
        |> assign(:selected_icon, type.icon || "none")
        |> assign(:meeting_mode, if(type.allow_video, do: "video", else: "personal"))
        |> assign(:selected_video_integration_id, Map.get(type, :video_integration_id))
        |> assign(:form_data, form_data)

      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_type, nil)
     |> assign(:show_edit_overlay, false)
     |> assign(:form_errors, %{})
     |> assign(:selected_icon, "none")
     |> assign(:form_data, %{})}
  end

  def handle_event("close_edit_overlay", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_type, nil)
     |> assign(:show_edit_overlay, false)
     |> assign(:form_errors, %{})
     |> assign(:selected_icon, "none")
     |> assign(:form_data, %{})}
  end

  # Validation is now handled inside MeetingTypeForm LiveComponent

  def handle_event("save_meeting_type", %{"meeting_type" => params}, socket) do
    socket = assign(socket, :saving, true)
    metadata = Helpers.get_security_metadata(socket)

    # First validate the meeting type form input
    case MeetingSettingsInputProcessor.validate_meeting_type_form(params, metadata: metadata) do
      {:ok, sanitized_params} ->
        ui_state = %{
          meeting_mode: Map.get(params, "meeting_mode", "personal"),
          selected_icon: Map.get(params, "icon", "none"),
          selected_video_integration_id:
            case Map.get(params, "video_integration_id") do
              nil ->
                nil

              "" ->
                nil

              id when is_integer(id) ->
                id

              id when is_binary(id) ->
                case Integer.parse(id) do
                  {int, _} -> int
                  :error -> nil
                end
            end
        }

        # Merge sanitized params with original params (keeping other fields)
        validated_params = Map.merge(params, sanitized_params)

        result =
          if socket.assigns.editing_type do
            MeetingTypes.update_meeting_type_from_form(
              socket.assigns.editing_type,
              validated_params,
              ui_state
            )
          else
            MeetingTypes.create_meeting_type_from_form(
              socket.assigns.current_user.id,
              validated_params,
              ui_state
            )
          end

        Helpers.handle_meeting_type_save_result(result, socket)

      {:error, validation_errors} ->
        {:noreply,
         socket
         |> assign(:form_errors, validation_errors)
         |> assign(:saving, false)}
    end
  end

  def handle_event("toggle_type", %{"id" => id}, socket) do
    type_id = String.to_integer(id)
    type = MeetingTypes.get_meeting_type(type_id, socket.assigns.current_user.id)

    if type do
      case MeetingTypes.toggle_meeting_type_status(type, %{is_active: !type.is_active}) do
        {:ok, _} ->
          send(self(), {:meeting_type_changed})
          Flash.info("Meeting type status updated")
          {:noreply, socket}

        {:error, _} ->
          Flash.error("Failed to update meeting type")
          {:noreply, socket}
      end
    else
      Flash.error("Meeting type not found")
      {:noreply, socket}
    end
  end

  def handle_event("show_delete_modal", %{"id" => id}, socket) do
    type_id = String.to_integer(id)
    type = MeetingTypes.get_meeting_type(type_id, socket.assigns.current_user.id)

    if type do
      {:noreply, ModalHook.show_modal(socket, :delete_meeting_type, type)}
    else
      Flash.error("Meeting type not found")
      {:noreply, socket}
    end
  end

  def handle_event("hide_delete_modal", _params, socket) do
    {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}
  end

  def handle_event("confirm_delete_meeting_type", _params, socket) do
    type = socket.assigns.delete_meeting_type_modal_data

    case MeetingTypes.delete_meeting_type(type) do
      {:ok, _} ->
        send(self(), {:meeting_type_changed})
        Flash.info("Meeting type deleted")
        {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}

      {:error, _} ->
        Flash.error("Failed to delete meeting type")
        {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container pb-16 lg:pb-20">
      <%= if @show_edit_overlay && @editing_type do %>
        <!-- Edit Meeting Type View -->
        <div class="space-y-6">
          <div class="flex items-center justify-between">
            <h2 class="text-2xl font-bold text-gray-800">Edit Meeting Type</h2>
            <.close_button
              phx_click="close_edit_overlay"
              phx_target={@myself}
              title="Close"
              show_label={true}
            />
          </div>

          <div class="card-glass p-6">
            <.live_component
              module={MeetingTypeForm}
              id={"meeting-type-form-edit-#{@editing_type.id}"}
              type={@editing_type}
              is_edit={true}
              video_integrations={@video_integrations}
              parent_myself={@myself}
              saving={@saving}
              current_user={@current_user}
              client_ip={@client_ip}
              user_agent={@user_agent}
              form_errors={@form_errors}
            />
          </div>
        </div>
      <% else %>
        <!-- Normal View -->
        <div class="space-y-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center">
              <DashboardComponents.section_header
                icon={:grid}
                title="Meeting Settings"
                class="flex items-center mb-0"
              />
            </div>

            <%= if @saving do %>
              <span class="text-green-400 text-sm flex items-center">
                <svg class="animate-spin h-4 w-4 mr-2" fill="none" viewBox="0 0 24 24">
                  <circle
                    class="opacity-25"
                    cx="12"
                    cy="12"
                    r="10"
                    stroke="currentColor"
                    stroke-width="4"
                  >
                  </circle>
                  <path
                    class="opacity-75"
                    fill="currentColor"
                    d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                  >
                  </path>
                </svg>
                Saving...
              </span>
            <% end %>
          </div>
          
    <!-- Meeting Types Section -->
          <div>
            <MeetingTypesListComponent.meeting_types_section
              meeting_types={@meeting_types}
              show_add_form={@show_add_form}
              editing_type={@editing_type}
              parent_myself={@myself}
            />
            
    <!-- Add Meeting Type Form (Moved to Top) -->
            <%= if @show_add_form do %>
              <div class="card-glass my-6">
                <h3 class="text-lg font-medium text-gray-800 mb-4">Add Meeting Type</h3>
                <.live_component
                  module={MeetingTypeForm}
                  id="meeting-type-form-new"
                  type={nil}
                  is_edit={false}
                  video_integrations={@video_integrations}
                  parent_myself={@myself}
                  saving={@saving}
                  current_user={@current_user}
                  client_ip={@client_ip}
                  user_agent={@user_agent}
                  form_errors={@form_errors}
                />
              </div>
            <% end %>
          </div>
          
    <!-- Scheduling Settings -->
          <.live_component
            module={SchedulingSettingsComponent}
            id="scheduling-settings"
            profile={@profile}
            client_ip={@client_ip}
            user_agent={@user_agent}
          />
        </div>
        
    <!-- Delete Meeting Type Modal -->
        <DeleteMeetingTypeModal.delete_meeting_type_modal
          show={@show_delete_meeting_type_modal}
          meeting_type={@delete_meeting_type_modal_data}
          myself={@myself}
        />
      <% end %>
      
    <!-- Add spacing after content to prevent flush bottom -->
      <div class="pb-8"></div>
    </div>
    """
  end

  # Meeting type form moved to TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
end
