defmodule TymeslotWeb.Dashboard.MeetingSettings.Card do
  @moduledoc """
  Component for displaying meeting type cards with toggle and action buttons.
  """
  use Phoenix.Component

  @doc """
  Renders a meeting type card with status toggle and action buttons.
  """
  attr :type, :map, required: true
  attr :myself, :any, required: true

  @spec meeting_type_card(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_type_card(assigns) do
    ~H"""
    <div class={[
      "card-glass",
      if(@type.is_active, do: "card-glass-available", else: "card-glass-unavailable")
    ]}>
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center">
          <%= if @type.icon && @type.icon != "none" do %>
            <span class={[@type.icon, "w-6 h-6 text-gray-600 mr-3"]} />
          <% end %>
          <div>
            <h3 class="text-lg font-medium text-gray-800">{@type.name}</h3>
            <p class="text-sm text-gray-600">{@type.duration_minutes} minutes</p>
          </div>
        </div>
        <button
          phx-click="toggle_type"
          phx-value-id={@type.id}
          phx-target={@myself}
          class={[
            "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-teal-500 focus:ring-offset-2",
            if(@type.is_active,
              do: "bg-teal-500 border-teal-500",
              else: "bg-gray-300 border-gray-300"
            )
          ]}
          role="switch"
          aria-checked={@type.is_active}
          aria-label={"Toggle #{@type.name} availability"}
        >
          <span class={[
            "pointer-events-none relative inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
            if(@type.is_active, do: "translate-x-5", else: "translate-x-0")
          ]}>
            <span class={[
              "absolute inset-0 flex h-full w-full items-center justify-center transition-opacity duration-200 ease-in-out",
              if(@type.is_active, do: "opacity-0", else: "opacity-100")
            ]}>
              <svg class="h-3 w-3 text-gray-400" fill="none" viewBox="0 0 12 12">
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
              <svg class="h-3 w-3 text-white" fill="currentColor" viewBox="0 0 12 12">
                <path d="M3.707 5.293a1 1 0 00-1.414 1.414l1.414-1.414zM5 7l-.707.707a1 1 0 001.414 0L5 7zm4.707-3.293a1 1 0 00-1.414-1.414l1.414 1.414zm-7.414 2l2 2 1.414-1.414-2-2-1.414 1.414zm3.414 2l4-4-1.414-1.414-4 4 1.414 1.414z" />
              </svg>
            </span>
          </span>
        </button>
      </div>

      <%= if @type.is_active do %>
        <!-- Meeting Type Details -->
        <div class="mb-4">
          <%= if @type.description do %>
            <p class="text-sm text-gray-600 mb-3">{@type.description}</p>
          <% end %>

          <div class="flex items-center space-x-4 text-sm text-gray-600">
            <div class="flex items-center">
              <svg class="w-4 h-4 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
              {@type.duration_minutes} min
            </div>
            <%= if @type.allow_video do %>
              <div class="flex items-center">
                <svg
                  class="w-4 h-4 mr-1 text-blue-400"
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
                <%= if @type.video_integration do %>
                  {@type.video_integration.name}
                <% else %>
                  Video meeting
                <% end %>
              </div>
            <% else %>
              <div class="flex items-center">
                <span class="hero-user w-4 h-4 mr-1" /> In-person
              </div>
            <% end %>
          </div>
        </div>
        
    <!-- Action Buttons -->
        <div class="flex items-center space-x-2">
          <button
            phx-click="edit_type"
            phx-value-id={@type.id}
            phx-target={@myself}
            class="btn btn-sm btn-primary"
          >
            <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
              />
            </svg>
            Edit
          </button>

          <button
            phx-click="show_delete_modal"
            phx-value-id={@type.id}
            phx-target={@myself}
            class="btn btn-sm btn-danger"
          >
            <svg class="w-3 h-3 mr-1" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
            Delete
          </button>
        </div>
      <% else %>
        <p class="text-gray-500 text-sm">Meeting type is currently disabled</p>
      <% end %>
    </div>
    """
  end
end
