defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm do
  @moduledoc """
  LiveComponent that renders and manages the Meeting Type form UI state.

  It handles local UI events (validate, icon selection, meeting mode toggle, provider selection)
  while the parent component handles the final submit/persist event.
  """
  use TymeslotWeb, :live_component

  # Follow project rule: ALWAYS alias nested modules and organize alphabetically within groups
  alias Phoenix.LiveView.JS
  alias Tymeslot.DatabaseSchemas.MeetingTypeSchema
  alias Tymeslot.Security.MeetingSettingsInputProcessor
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  # Use provider icon component locally
  import TymeslotWeb.Components.Icons.ProviderIcon

  # Public assigns passed from parent
  # - type: existing meeting type or nil
  # - is_edit: whether we are editing
  # - video_integrations: list for selection
  # - parent_myself: phx-target for parent events (submit/cancel)
  # - saving: parent's saving state to control the button disabled state
  # - current_user: used for security metadata in validation

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:form_errors, %{})
     |> assign(:form_data, %{})
     |> assign(:selected_icon, "none")
     |> assign(:meeting_mode, "personal")
     |> assign(:selected_video_integration_id, nil)
     |> assign(:__initialized__, false)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    {:ok, maybe_initialize(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <form phx-submit="save_meeting_type" phx-target={@parent_myself} class="space-y-4">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <div>
          <label for="type_name" class="label">
            Name
          </label>
          <input
            type="text"
            id="type_name"
            name="meeting_type[name]"
            value={Map.get(@form_data, "name", if(@type, do: @type.name, else: ""))}
            required
            class={[
              "input",
              if(Map.get(@form_errors, :name), do: "input-error", else: "")
            ]}
            placeholder="e.g., Quick Chat"
            phx-change="validate_meeting_type"
            phx-target={@myself}
          />
          <%= if errors = Map.get(@form_errors, :name) do %>
            <p class="form-error">{Helpers.format_errors(errors)}</p>
          <% end %>
        </div>

        <div>
          <label for="type_duration" class="label">
            Duration (minutes)
          </label>
          <input
            type="number"
            id="type_duration"
            name="meeting_type[duration]"
            value={Map.get(@form_data, "duration", if(@type, do: @type.duration_minutes, else: "30"))}
            min="5"
            max="480"
            step="5"
            required
            class={[
              "input",
              if(Map.get(@form_errors, :duration), do: "input-error", else: "")
            ]}
            placeholder="30"
            phx-change="validate_meeting_type"
            phx-target={@myself}
          />
          <%= if errors = Map.get(@form_errors, :duration) do %>
            <p class="form-error">{Helpers.format_errors(errors)}</p>
          <% end %>
          <p class="mt-1 text-sm text-gray-600">
            Enter a duration between 5 and 480 minutes
          </p>
        </div>
      </div>

      <div>
        <label for="type_description" class="label">
          Description (optional)
        </label>
        <textarea
          id="type_description"
          name="meeting_type[description]"
          rows="3"
          class={[
            "textarea",
            if(Map.get(@form_errors, :description), do: "input-error", else: "")
          ]}
          placeholder="Brief description of this meeting type"
          phx-change="validate_meeting_type"
          phx-target={@myself}
        ><%= Map.get(@form_data, "description", if(@type, do: @type.description, else: "")) %></textarea>
        <%= if errors = Map.get(@form_errors, :description) do %>
          <p class="form-error">{Helpers.format_errors(errors)}</p>
        <% end %>
      </div>

      <div>
        <label class="label">
          Icon
        </label>
        <div class="grid grid-cols-8 sm:grid-cols-10 md:grid-cols-14 lg:grid-cols-16 gap-1">
          <%= for {icon_value, icon_name} <- MeetingTypeSchema.valid_icons_with_names() do %>
            <button
              type="button"
              phx-click={JS.push("select_icon", value: %{icon: icon_value}, target: @myself)}
              class={[
                "relative rounded-md border-2 transition-colors duration-200 group",
                "w-10 h-10 flex items-center justify-center overflow-hidden",
                if(@selected_icon == icon_value,
                  do: "bg-gradient-to-br from-teal-50 to-teal-100 border-teal-500 shadow-md",
                  else: "bg-white/50 border-gray-300/50 hover:border-teal-400/50 hover:bg-white/70"
                )
              ]}
              style="width: 40px; height: 40px; min-width: 40px; min-height: 40px; max-width: 40px; max-height: 40px;"
              title={icon_name}
            >
              <%= if icon_value == "none" do %>
                <svg
                  class="w-6 h-6 text-gray-400"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              <% else %>
                <span
                  class={[
                    icon_value,
                    "block",
                    if(@selected_icon == icon_value,
                      do: "text-teal-600",
                      else: "text-gray-500 group-hover:text-teal-500"
                    )
                  ]}
                  style="width: 32px; height: 32px; min-width: 32px; min-height: 32px;"
                />
              <% end %>
            </button>
          <% end %>
        </div>
        <p class="mt-2 text-sm text-gray-600">
          Choose an icon to represent this meeting type, or select "No Icon" for no visual indicator.
        </p>
        <%= if errors = Map.get(@form_errors, :icon) do %>
          <p class="form-error">{Helpers.format_errors(errors)}</p>
        <% end %>
      </div>

      <div>
        <label class="label">
          Meeting Type
        </label>
        <div class="flex items-center space-x-4">
          <button
            type="button"
            phx-click={JS.push("toggle_meeting_mode", value: %{mode: "personal"}, target: @myself)}
            class={[
              "flex-1 py-4 px-4 rounded-lg border-2 transition-all duration-200 box-border h-16",
              "hover:scale-[1.02] hover:shadow-lg flex items-center justify-center",
              if(@meeting_mode == "personal",
                do: "glass-gradient border-teal-500 shadow-lg shadow-teal-500/20",
                else: "card-glass border-gray-300/20 hover:border-teal-400/50"
              )
            ]}
          >
            <div class="flex items-center justify-center space-x-2">
              <span class={[
                "hero-user w-5 h-5",
                if(@meeting_mode == "personal", do: "text-teal-600", else: "text-gray-600")
              ]} />
              <span class="font-medium">In-Person</span>
            </div>
          </button>

          <button
            type="button"
            phx-click={JS.push("toggle_meeting_mode", value: %{mode: "video"}, target: @myself)}
            class={[
              "flex-1 py-4 px-4 rounded-lg border-2 transition-all duration-200 box-border h-16",
              "hover:scale-[1.02] hover:shadow-lg flex items-center justify-center",
              if(@meeting_mode == "video",
                do: "glass-gradient border-teal-500 shadow-lg shadow-teal-500/20",
                else: "card-glass border-gray-300/20 hover:border-teal-400/50"
              )
            ]}
          >
            <div class="flex items-center justify-center space-x-2">
              <span class={[
                "hero-video-camera w-5 h-5",
                if(@meeting_mode == "video", do: "text-teal-600", else: "text-gray-600")
              ]} />
              <span class="font-medium">Video Meeting</span>
            </div>
          </button>
        </div>

        <%= if @meeting_mode == "video" do %>
          <div class="mt-4">
            <label class="label text-sm">
              Select Video Provider
            </label>
            <%= if @video_integrations == [] do %>
              <div class="p-4 bg-yellow-500/10 border border-yellow-500/30 rounded-lg">
                <p class="text-sm text-yellow-700">
                  No video integrations configured.
                  <a href="/dashboard/video-integrations" class="underline hover:text-yellow-800">
                    Set up video integration
                  </a>
                </p>
              </div>
            <% else %>
              <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-2">
                <%= for integration <- @video_integrations do %>
                  <button
                    type="button"
                    phx-click={
                      JS.push("select_video_integration",
                        value: %{id: integration.id},
                        target: @myself
                      )
                    }
                    class={[
                      "p-2 rounded-lg border-2 transition-all duration-200 box-border h-20 flex items-center justify-center",
                      "hover:scale-[1.02] hover:shadow-lg",
                      if(@selected_video_integration_id == integration.id,
                        do: "glass-gradient border-teal-500 shadow-lg shadow-teal-500/20",
                        else: "card-glass border-gray-300/20 hover:border-teal-400/50"
                      )
                    ]}
                    title={integration.name}
                  >
                    <div class="flex flex-col items-center justify-center space-y-1">
                      <.provider_icon provider={integration.provider} size="compact" />
                      <span class={[
                        "text-sm font-medium truncate max-w-full",
                        if(@selected_video_integration_id == integration.id,
                          do: "text-teal-700",
                          else: "text-gray-700"
                        )
                      ]}>
                        {integration.name}
                      </span>
                    </div>
                  </button>
                <% end %>
              </div>
              <%= if errors = Map.get(@form_errors, :video_integration) do %>
                <p class="form-error mt-2">{Helpers.format_errors(errors)}</p>
              <% end %>
            <% end %>
          </div>
        <% end %>
      </div>
      
    <!-- Hidden fields -->
      <input
        type="hidden"
        name="meeting_type[is_active]"
        value={if @type, do: to_string(@type.is_active), else: "true"}
      />
      <input type="hidden" name="meeting_type[meeting_mode]" value={@meeting_mode} />
      <input
        type="hidden"
        name="meeting_type[video_integration_id]"
        value={@selected_video_integration_id}
      />
      <input type="hidden" name="meeting_type[icon]" value={@selected_icon} />

      <%= if errors = Map.get(@form_errors, :base) do %>
        <p class="form-error">{Helpers.format_errors(errors)}</p>
      <% end %>

      <div class="flex justify-end space-x-3">
        <button
          type="button"
          phx-click={if @is_edit, do: "close_edit_overlay", else: "toggle_add_form"}
          phx-target={@myself}
          class="btn btn-secondary"
        >
          Cancel
        </button>
        <button type="submit" disabled={@saving} class="btn btn-primary">
          <%= if @saving do %>
            <span class="flex items-center">
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
          <% else %>
            {if @is_edit, do: "Update", else: "Create"} Meeting Type
          <% end %>
        </button>
      </div>
    </form>
    """
  end

  @impl true
  def handle_event("validate_meeting_type", %{"meeting_type" => params}, socket) do
    metadata = Helpers.get_security_metadata(socket)

    # Merge incoming params into existing form data to prevent wiping other fields
    new_data = Map.merge(socket.assigns.form_data || %{}, params)

    # Determine which fields changed (input-level phx-change sends only the targeted field)
    changed_fields = Map.keys(params)

    # Start from existing errors and update only the changed fields
    current_errors = socket.assigns.form_errors || %{}

    {updated_data, updated_errors} =
      Enum.reduce(changed_fields, {new_data, current_errors}, fn field, {acc_data, acc_errors} ->
        validate_and_update_field(field, Map.get(params, field), metadata, acc_data, acc_errors)
      end)

    {:noreply, assign(socket, form_data: updated_data, form_errors: updated_errors)}
  end

  @impl true
  def handle_event("toggle_meeting_mode", %{"mode" => mode}, socket) do
    socket =
      socket
      |> assign(:meeting_mode, mode)
      |> assign(
        :selected_video_integration_id,
        if(mode == "video" && length(socket.assigns.video_integrations || []) == 1,
          do: hd(socket.assigns.video_integrations).id,
          else: nil
        )
      )
      |> assign(:form_errors, Map.delete(socket.assigns.form_errors, :video_integration))

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_icon", %{"icon" => icon}, socket) do
    {:noreply, assign(socket, :selected_icon, icon)}
  end

  @impl true
  def handle_event("select_video_integration", %{"id" => id}, socket) do
    integration_id =
      case id do
        id when is_binary(id) -> String.to_integer(id)
        id when is_integer(id) -> id
      end

    socket =
      socket
      |> assign(:selected_video_integration_id, integration_id)
      |> assign(:form_errors, Map.delete(socket.assigns.form_errors, :video_integration))

    {:noreply, socket}
  end

  # --- Private helpers ---
  defp validate_and_update_field("name", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputProcessor.validate_meeting_type_field(:name, value,
           metadata: metadata
         ) do
      {:ok, sanitized} -> {Map.put(acc_data, "name", sanitized), Map.delete(acc_errors, :name)}
      {:error, %{name: msg}} -> {acc_data, Map.put(acc_errors, :name, msg)}
      {:error, _} -> {acc_data, acc_errors}
    end
  end

  defp validate_and_update_field("duration", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputProcessor.validate_meeting_type_field(:duration, value,
           metadata: metadata
         ) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "duration", sanitized), Map.delete(acc_errors, :duration)}

      {:error, %{duration: msg}} ->
        {acc_data, Map.put(acc_errors, :duration, msg)}

      {:error, _} ->
        {acc_data, acc_errors}
    end
  end

  defp validate_and_update_field("description", value, metadata, acc_data, acc_errors) do
    case MeetingSettingsInputProcessor.validate_meeting_type_field(:description, value,
           metadata: metadata
         ) do
      {:ok, sanitized} ->
        {Map.put(acc_data, "description", sanitized), Map.delete(acc_errors, :description)}

      {:error, %{description: msg}} ->
        {acc_data, Map.put(acc_errors, :description, msg)}

      {:error, _} ->
        {acc_data, acc_errors}
    end
  end

  defp validate_and_update_field(_other, _value, _metadata, acc_data, acc_errors),
    do: {acc_data, acc_errors}

  defp maybe_initialize(%{assigns: %{__initialized__: true}} = socket), do: socket

  defp maybe_initialize(%{assigns: assigns} = socket) do
    type = Map.get(assigns, :type)

    socket
    |> assign(:selected_icon, get_selected_icon(type))
    |> assign(:meeting_mode, get_meeting_mode(type))
    |> assign(:selected_video_integration_id, get_video_integration_id(type))
    |> assign(:form_data, build_form_data(type))
    |> assign(:__initialized__, true)
  end

  defp get_selected_icon(nil), do: "none"
  defp get_selected_icon(%{icon: icon}) when is_binary(icon) and icon != "", do: icon
  defp get_selected_icon(_), do: "none"

  defp get_meeting_mode(%{allow_video: true}), do: "video"
  defp get_meeting_mode(_), do: "personal"

  defp get_video_integration_id(nil), do: nil
  defp get_video_integration_id(%{video_integration_id: nil}), do: nil
  defp get_video_integration_id(%{video_integration_id: id}) when is_integer(id), do: id

  defp get_video_integration_id(%{video_integration_id: id}) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp get_video_integration_id(_), do: nil

  defp build_form_data(nil) do
    %{"name" => "", "duration" => "30", "description" => "", "icon" => "none"}
  end

  defp build_form_data(type) do
    %{
      "name" => type.name || "",
      "duration" => to_string(type.duration_minutes || 30),
      "description" => type.description || "",
      "icon" => type.icon || "none"
    }
  end
end
