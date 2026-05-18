defmodule TymeslotWeb.Dashboard.MeetingSettings.Card do
  @moduledoc """
  Component for displaying meeting type cards with toggle and action buttons.
  """
  use Phoenix.Component
  alias Tymeslot.Integrations.Calendar.DisplayHelpers
  alias TymeslotWeb.Components.Icons.ProviderIcon

  @doc """
  Renders a meeting type card with status toggle and action buttons.
  """
  attr :type, :map, required: true
  attr :myself, :any, required: true
  attr :icon_size, :string, default: "mini", values: ["compact", "medium", "large", "mini"]

  @spec meeting_type_card(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_type_card(assigns) do
    ~H"""
    <div class={[
      "card-glass py-3 px-4",
      if(@type.is_active, do: "card-glass-available", else: "card-glass-unavailable")
    ]}>
      <div class="flex items-center gap-3">
        <%!-- Drag Handle --%>
        <div class="cursor-grab active:cursor-grabbing text-tymeslot-400 flex-shrink-0">
          <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 8h16M4 16h16"
            />
          </svg>
        </div>

        <%= if @type.icon && @type.icon != "none" do %>
          <span class={[@type.icon, "w-5 h-5 text-tymeslot-600 flex-shrink-0"]} />
        <% end %>

        <%!-- Name + details --%>
        <div class="flex-1 min-w-0">
          <h3 class="text-token-base font-medium text-tymeslot-800 truncate">
            {@type.name}
          </h3>
          <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 mt-0.5 text-token-xs text-tymeslot-600">
            <span class="flex items-center flex-shrink-0">
              <svg class="w-3.5 h-3.5 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              {@type.duration_minutes} min
            </span>
            <%= if @type.allow_video do %>
              <span class="flex items-center min-w-0">
                <%= if @type.video_integration do %>
                  <span class="mr-1.5 flex-shrink-0">
                    <ProviderIcon.provider_icon
                      provider={@type.video_integration.provider}
                      size={@icon_size}
                    />
                  </span>
                  <span class="truncate max-w-[10rem]">
                    {@type.video_integration.name}
                  </span>
                <% else %>
                  <svg
                    class="w-3.5 h-3.5 mr-1 text-blue-400 flex-shrink-0"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
                    />
                  </svg>
                  <span>Video</span>
                <% end %>
              </span>
            <% else %>
              <span class="flex items-center">
                <ProviderIcon.provider_icon provider="in_person" size={@icon_size} class="mr-1" />
                <span>In-person</span>
              </span>
            <% end %>
            <%= if @type.calendar_integration do %>
              <span class="flex items-center min-w-0">
                <span class="mr-1.5 flex-shrink-0">
                  <ProviderIcon.provider_icon
                    provider={@type.calendar_integration.provider}
                    size={@icon_size}
                  />
                </span>
                <span class="truncate max-w-[8rem]">
                  {@type.calendar_integration.name}
                </span>
                <span class="ml-1 text-tymeslot-500 flex-shrink-0">
                  ({calendar_display_name(@type)})
                </span>
              </span>
            <% end %>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex items-center gap-1.5 flex-shrink-0">
          <button
            phx-click="edit_type"
            phx-value-id={@type.id}
            phx-target={@myself}
            class="p-1.5 text-tymeslot-500 hover:text-tymeslot-700 hover:bg-tymeslot-100 rounded-lg transition-colors"
            title="Edit"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
              />
            </svg>
          </button>

          <button
            phx-click="show_delete_modal"
            phx-value-id={@type.id}
            phx-target={@myself}
            class="p-1.5 text-red-400 hover:text-red-600 hover:bg-red-50 rounded-lg transition-colors"
            title="Delete"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
          </button>

          <button
            phx-click="toggle_type"
            phx-value-id={@type.id}
            phx-target={@myself}
            class={[
              "relative inline-flex h-5 w-9 flex-shrink-0 cursor-pointer rounded-full border-2 transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-teal-500 focus:ring-offset-2",
              if(@type.is_active,
                do: "bg-teal-500 border-teal-500",
                else: "bg-tymeslot-300 border-tymeslot-300"
              )
            ]}
            role="switch"
            aria-checked={@type.is_active}
            aria-label={"Toggle #{@type.name} availability"}
          >
            <span class={[
              "pointer-events-none relative inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
              if(@type.is_active, do: "translate-x-4", else: "translate-x-0")
            ]}>
              <span class={[
                "absolute inset-0 flex h-full w-full items-center justify-center transition-opacity duration-200 ease-in-out",
                if(@type.is_active, do: "opacity-0", else: "opacity-100")
              ]}>
                <svg class="h-2.5 w-2.5 text-tymeslot-400" fill="none" viewBox="0 0 12 12">
                  <path
                    d="M4 8l2-2m0 0l2-2M6 6L4 4m2 2l2 2"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  />
                </svg>
              </span>
              <span class={[
                "absolute inset-0 flex h-full w-full items-center justify-center transition-opacity duration-200 ease-in-out",
                if(@type.is_active, do: "opacity-100", else: "opacity-0")
              ]}>
                <svg class="h-2.5 w-2.5 text-white" fill="currentColor" viewBox="0 0 12 12">
                  <path d="M3.707 5.293a1 1 0 00-1.414 1.414l1.414-1.414zM5 7l-.707.707a1 1 0 001.414 0L5 7zm4.707-3.293a1 1 0 00-1.414-1.414l1.414 1.414zm-7.414 2l2 2 1.414-1.414-2-2-1.414 1.414zm3.414 2l4-4-1.414-1.414-4 4 1.414 1.414z" />
                </svg>
              </span>
            </span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp calendar_display_name(%{calendar_integration: nil}), do: "Calendar"

  defp calendar_display_name(%{calendar_integration: integration} = type) do
    calendar =
      Enum.find(integration.calendar_list || [], fn cal ->
        (cal["id"] || cal[:id]) == type.target_calendar_id
      end)

    name =
      if calendar do
        DisplayHelpers.extract_calendar_display_name(calendar)
      else
        "Calendar"
      end

    truncate_calendar_name(name)
  end

  defp truncate_calendar_name(name) when is_binary(name) do
    max_length = 15
    ellipsis = "..."

    if String.length(name) > max_length do
      String.slice(name, 0, max_length - String.length(ellipsis)) <> ellipsis
    else
      name
    end
  end
end
