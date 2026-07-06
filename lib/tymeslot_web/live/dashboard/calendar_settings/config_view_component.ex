defmodule TymeslotWeb.Dashboard.CalendarSettings.ConfigViewComponent do
  @moduledoc """
  LiveComponent that owns the provider-setup screen of the calendar
  settings dashboard: filling the credentials form, discovering
  calendars, and creating the integration.

  Mounted by `CalendarSettingsComponent` whenever the user picks a
  provider card. On success or cancel, it asks the parent to switch
  back to the providers list via `send_update/2`.
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias Tymeslot.Integrations.Calendar.InputValidation, as: CalendarInputValidation
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.ChangesetUtils
  alias Tymeslot.Utils.SanitizeMerge
  alias TymeslotWeb.Dashboard.CalendarSettings.Components
  alias TymeslotWeb.Dashboard.CalendarSettingsComponent
  alias TymeslotWeb.Live.Shared.Flash
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @caldav_providers ProviderConfig.caldav_based_providers()
  @parent_component_id "calendar-settings"

  @impl Phoenix.LiveComponent
  def mount(socket) do
    {:ok, reset_form_state(socket)}
  end

  @impl Phoenix.LiveComponent
  def update(%{selected_provider: provider} = assigns, socket) do
    socket =
      if Map.get(socket.assigns, :selected_provider) != provider do
        socket |> assign(assigns) |> reset_form_state()
      else
        assign(socket, assigns)
      end

    {:ok, socket}
  end

  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl Phoenix.LiveComponent
  def handle_event("back_to_providers", _params, socket) do
    back_to_grid()
    {:noreply, reset_form_state(socket)}
  end

  def handle_event("validate_field", %{"field" => field} = params, socket) do
    value = Map.get(params, "value", Map.get(socket.assigns.form_values, field, ""))
    form_values = Map.put(socket.assigns.form_values, field, value)
    socket = assign(socket, :form_values, form_values)

    field_atom =
      case field do
        "name" -> :name
        "url" -> :url
        "username" -> :username
        "password" -> :password
        _other -> nil
      end

    if field_atom do
      if String.trim(to_string(value)) == "" do
        {:noreply,
         assign(
           socket,
           :form_errors,
           FormValidationHelpers.delete_field_error(socket.assigns.form_errors, field_atom)
         )}
      else
        case CalendarInputValidation.validate_single_field(field_atom, value,
               metadata: socket.assigns.security_metadata
             ) do
          {:ok, _result} ->
            {:noreply,
             assign(
               socket,
               :form_errors,
               FormValidationHelpers.delete_field_error(socket.assigns.form_errors, field_atom)
             )}

          {:error, error} ->
            {:noreply,
             assign(
               socket,
               :form_errors,
               Map.put(socket.assigns.form_errors, field_atom, error)
             )}
        end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("track_form_change", %{"integration" => params}, socket) do
    {:noreply, assign(socket, :form_values, params)}
  end

  def handle_event("discover_calendars", %{"integration" => params}, socket) do
    provider = normalize_provider(params["provider"] || socket.assigns.selected_provider)

    socket =
      socket
      |> assign(:is_saving, true)
      |> assign(:form_values, params)
      |> assign(:form_errors, %{})

    case CalendarInputValidation.validate_calendar_discovery(params,
           metadata: socket.assigns.security_metadata,
           provider: provider
         ) do
      {:error, validation_errors} ->
        {:noreply, assign(socket, form_errors: validation_errors, is_saving: false)}

      {:ok, sanitized_params} ->
        user_id = socket.assigns.current_user.id

        case RateLimiter.check_calendar_discovery_rate_limit(user_id) do
          {:error, :rate_limited, message} ->
            Flash.error(message)
            {:noreply, assign(socket, :is_saving, false)}

          :ok ->
            do_discover_calendars(provider, sanitized_params, socket)
        end
    end
  end

  def handle_event("add_integration", %{"integration" => params} = full_params, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check_integration_write_rate_limit(user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        {:noreply, socket}

      :ok ->
        socket = assign(socket, is_saving: true, form_values: params)

        processed_params =
          case Map.get(full_params, "selected_calendars") do
            calendars when is_list(calendars) ->
              selection =
                Calendar.prepare_selection_params(calendars, socket.assigns.discovered_calendars)

              SanitizeMerge.merge(params, selection)

            _other ->
              params
          end

        case Calendar.create_integration_with_validation(
               user_id,
               processed_params,
               metadata: socket.assigns.security_metadata
             ) do
          {:ok, _integration} ->
            send(self(), {:integration_added, :calendar})
            Flash.info("Calendar integration added successfully")
            close_modal()
            {:noreply, reset_form_state(socket)}

          {:error, :duplicate_integration} ->
            {:noreply,
             assign(socket,
               form_errors: %{
                 generic: ["A calendar integration with this configuration already exists"]
               },
               is_saving: false
             )}

          {:error, {:form_errors, errors}} ->
            {:noreply, assign(socket, form_errors: errors, is_saving: false)}

          {:error, {:changeset, changeset}} ->
            {:noreply,
             assign(socket,
               form_errors: %{generic: [ChangesetUtils.get_first_error(changeset)]},
               is_saving: false
             )}
        end
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div>
      <Components.config_view
        selected_provider={@selected_provider}
        myself={@myself}
        security_metadata={@security_metadata}
        form_errors={@form_errors}
        form_values={@form_values}
        discovered_calendars={@discovered_calendars}
        show_calendar_selection={@show_calendar_selection}
        discovery_credentials={@discovery_credentials}
        is_saving={@is_saving}
      />
    </div>
    """
  end

  defp do_discover_calendars(provider, sanitized_params, socket) do
    case Calendar.discover_and_filter_calendars(
           provider,
           sanitized_params["url"],
           sanitized_params["username"],
           sanitized_params["password"]
         ) do
      {:ok, %{calendars: calendars, discovery_credentials: credentials}} ->
        {:noreply,
         socket
         |> assign(:discovered_calendars, calendars)
         |> assign(:discovery_credentials, credentials)
         |> assign(:show_calendar_selection, true)
         |> assign(:is_saving, false)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:form_errors, %{discovery: DisplayHelpers.normalize_discovery_error(reason)})
         |> assign(:is_saving, false)}
    end
  end

  # Cancel: return to the picker grid but keep the modal open.
  defp back_to_grid do
    send_update(CalendarSettingsComponent, id: @parent_component_id, selected_provider: nil)
  end

  # Success: close the whole picker modal.
  defp close_modal do
    send_update(CalendarSettingsComponent,
      id: @parent_component_id,
      selected_provider: nil,
      show_picker: false
    )
  end

  defp reset_form_state(socket) do
    assign(socket,
      form_values: %{},
      form_errors: %{},
      discovered_calendars: [],
      show_calendar_selection: false,
      discovery_credentials: %{},
      is_saving: false
    )
  end

  defp normalize_provider(p) when p in @caldav_providers, do: p

  defp normalize_provider(p) when is_binary(p) do
    atom = String.to_existing_atom(p)
    if atom in @caldav_providers, do: atom, else: :caldav
  rescue
    ArgumentError -> :caldav
  end

  defp normalize_provider(_other_provider), do: :caldav
end
