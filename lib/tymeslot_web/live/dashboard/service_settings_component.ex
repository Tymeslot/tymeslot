defmodule TymeslotWeb.Dashboard.ServiceSettingsComponent do
  @moduledoc """
  LiveComponent for managing meeting settings in the dashboard.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.InputValidation, as: MeetingSettingsInputValidation
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Components.Dashboard.MeetingTypes.DeleteMeetingTypeModal
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypesListComponent
  alias TymeslotWeb.Dashboard.MeetingSettings.SchedulingSettingsComponent
  require Logger

  @impl Phoenix.LiveComponent
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
     |> assign(:toggling_type_id, nil)
     |> ModalHook.mount_modal(delete_meeting_type: false)}
  end

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Merge new assigns into socket
    socket = assign(socket, assigns)

    # Always ensure we have the latest profile data
    socket = Helpers.maybe_reload_profile(socket)

    # Load meeting settings data directly (own your data)
    # Use socket.assigns to handle partial updates from send_update
    user_id = socket.assigns.current_user.id
    data = DashboardContext.get_meeting_settings_data(user_id)

    socket =
      socket
      |> assign(:meeting_types, data.meeting_types)
      |> assign(:video_integrations, data.video_integrations)
      |> assign(:calendar_integrations, data.calendar_integrations)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
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
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      do_save_meeting_type(params, socket)
    end)
  end

  def handle_event("toggle_type", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    type_id = String.to_integer(id)

    if socket.assigns.toggling_type_id == type_id do
      {:noreply, socket}
    else
      with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
        socket
        |> assign(:toggling_type_id, type_id)
        |> do_toggle_type(type_id, user_id)
      end)
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
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      type = socket.assigns.delete_meeting_type_modal_data

      case MeetingTypes.delete_meeting_type(type) do
        {:ok, _result} ->
          send(self(), {:meeting_type_changed})
          Flash.info("Meeting type deleted")
          {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}

        {:error, _reason} ->
          Flash.error("Failed to delete meeting type")
          {:noreply, ModalHook.hide_modal(socket, :delete_meeting_type)}
      end
    end)
  end

  def handle_event("reorder_meeting_types", %{"ids" => ids}, socket) when is_list(ids) do
    user_id = socket.assigns.current_user.id

    with_rate_limit(RateLimiter.check_meeting_type_write_rate_limit(user_id), socket, fn ->
      # Convert to integers safely
      meeting_type_ids =
        ids
        |> Enum.map(fn
          id when is_integer(id) ->
            id

          id when is_binary(id) ->
            case Integer.parse(id) do
              {int, _value} -> int
              :error -> nil
            end

          _other ->
            nil
        end)
        |> Enum.reject(&is_nil/1)

      case MeetingTypes.reorder_meeting_types(user_id, meeting_type_ids) do
        {:ok, _result} ->
          send(self(), {:meeting_type_changed})
          Flash.info("Meeting types reordered")
          {:noreply, socket}

        {:error, reason} ->
          Logger.error("Failed to reorder meeting types", reason: inspect(reason))
          Flash.error("Failed to reorder meeting types")
          {:noreply, socket}
      end
    end)
  end

  # Private functions

  defp do_toggle_type(socket, type_id, user_id) do
    case MeetingTypes.get_meeting_type(type_id, user_id) do
      nil ->
        Flash.error("Meeting type not found")
        {:noreply, assign(socket, :toggling_type_id, nil)}

      type ->
        case MeetingTypes.toggle_meeting_type_status(type, %{is_active: !type.is_active}) do
          {:ok, updated_type} ->
            send(self(), {:meeting_type_changed})
            Flash.info("Meeting type status updated")

            updated_meeting_types =
              Enum.map(socket.assigns.meeting_types, fn
                t when t.id == updated_type.id -> updated_type
                t -> t
              end)

            {:noreply,
             assign(socket, meeting_types: updated_meeting_types, toggling_type_id: nil)}

          {:error, _reason} ->
            Flash.error("Failed to update meeting type")
            {:noreply, assign(socket, :toggling_type_id, nil)}
        end
    end
  end

  defp with_rate_limit({:error, :rate_limited, message}, socket, _action) do
    Flash.error(message)
    {:noreply, socket}
  end

  defp with_rate_limit(:ok, _socket, action), do: action.()

  defp do_save_meeting_type(params, socket) do
    socket = assign(socket, :saving, true)
    metadata = Helpers.get_security_metadata(socket)

    # First validate the meeting type form input
    case MeetingSettingsInputValidation.validate_meeting_type_form(params, metadata: metadata) do
      {:ok, sanitized_params} ->
        ui_state = %{
          meeting_mode: Map.get(sanitized_params, "meeting_mode", "personal"),
          selected_icon: Map.get(sanitized_params, "icon", "none"),
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
                  {int, _value} -> int
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

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header
        icon={:grid}
        title="Meeting Settings"
        saving={@saving}
      />

      <%= if (@show_edit_overlay && @editing_type) || @show_add_form do %>
        <%!-- Form View (Add or Edit) --%>
        <div
          id="meeting-type-config-view"
          phx-hook="ScrollReset"
          data-action={if @editing_type, do: "edit-#{@editing_type.id}", else: "new"}
          class="space-y-8 animate-in fade-in slide-in-from-bottom-4 duration-500"
        >
          <div class="flex items-start justify-between bg-white p-6 rounded-token-3xl border-2 border-tymeslot-50 shadow-sm">
            <.section_header
              level={2}
              icon={:grid}
              title={if @editing_type, do: "Edit Meeting Type", else: "Add Meeting Type"}
            />
            <button
              phx-click={if @editing_type, do: "close_edit_overlay", else: "toggle_add_form"}
              phx-target={@myself}
              class="flex-shrink-0 p-2 rounded-lg text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 transition-colors"
              title="Close"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>

          <div class="card-glass">
            <.live_component
              module={MeetingTypeForm}
              id={if @editing_type, do: "meeting-type-form-edit-#{@editing_type.id}", else: "meeting-type-form-new"}
              type={@editing_type}
              is_edit={!!@editing_type}
              video_integrations={@video_integrations}
              calendar_integrations={@calendar_integrations}
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
        <%!-- Normal View --%>
        <div class="space-y-10">
          <%!-- Meeting Types Section --%>
          <div class="space-y-6">
            <MeetingTypesListComponent.meeting_types_section
              meeting_types={@meeting_types}
              show_add_form={@show_add_form}
              editing_type={@editing_type}
              parent_myself={@myself}
            />
          </div>

    <%!-- Scheduling Settings --%>
          <div class="animate-in fade-in duration-700">
            <.live_component
              module={SchedulingSettingsComponent}
              id="scheduling-settings"
              profile={@profile}
              client_ip={@client_ip}
              user_agent={@user_agent}
            />
          </div>
        </div>

    <%!-- Delete Meeting Type Modal --%>
        <DeleteMeetingTypeModal.delete_meeting_type_modal
          show={@show_delete_meeting_type_modal}
          meeting_type={@delete_meeting_type_modal_data}
          myself={@myself}
        />
      <% end %>

    <%!-- Add spacing after content to prevent flush bottom --%>
      <div class="pb-8"></div>
    </div>
    """
  end
end
