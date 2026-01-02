defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig do
  @moduledoc """
  Component for configuring custom video link integration.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative">
      <!-- Header with Close Button -->
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center">
          <div class="text-gray-600 mr-3">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
              />
            </svg>
          </div>
          <h3 class="text-lg font-semibold text-gray-800">Setup Custom Video Link</h3>
        </div>
        <UIComponents.close_button target={@target} />
      </div>
      
    <!-- Info Section -->
      <.custom_video_info />

      <div class="border-t border-purple-200/30 my-6"></div>
      
    <!-- Configuration Form with Glass Morphism -->
      <form phx-submit="add_integration" phx-target={@target} class="space-y-6">
        <input type="hidden" name="integration[provider]" value="custom" />
        
    <!-- Integration Name Field -->
        <div>
          <label for="integration_name" class="block text-sm font-semibold text-neutral-700 mb-2">
            Integration Name
          </label>
          <div class="relative">
            <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
              <svg
                class="w-5 h-5 text-neutral-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z"
                />
              </svg>
            </div>
            <input
              type="text"
              id="integration_name"
              name="integration[name]"
              value={Map.get(@form_values, "name", "")}
              phx-blur="validate_field"
              phx-value-field="name"
              phx-target={@target}
              required
              class={[
                "w-full pl-10 pr-3 py-2.5 border rounded-lg",
                "bg-white/50 backdrop-blur-sm",
                "focus:outline-none focus:ring-2 focus:ring-turquoise-500 focus:border-transparent",
                "transition-all duration-200",
                if(Map.get(@form_errors, :name),
                  do: "border-red-300 text-red-900 placeholder-red-300",
                  else: "border-purple-200/50 text-neutral-700 placeholder-neutral-400"
                )
              ]}
              placeholder="My Custom Video Service"
            />
          </div>
          <%= if error = Map.get(@form_errors, :name) do %>
            <p class="mt-1 text-sm text-red-600 flex items-center">
              <svg class="w-4 h-4 mr-1" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
              {error}
            </p>
          <% end %>
        </div>
        
    <!-- Video Meeting URL Field -->
        <div>
          <label
            for="integration_custom_meeting_url"
            class="block text-sm font-semibold text-neutral-700 mb-2"
          >
            Video Meeting URL
          </label>
          <div class="relative">
            <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
              <svg
                class="w-5 h-5 text-neutral-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                />
              </svg>
            </div>
            <input
              type="url"
              id="integration_custom_meeting_url"
              name="integration[custom_meeting_url]"
              value={Map.get(@form_values, "custom_meeting_url", "")}
              phx-blur="validate_field"
              phx-value-field="custom_meeting_url"
              phx-target={@target}
              required
              class={[
                "w-full pl-10 pr-3 py-2.5 border rounded-lg",
                "bg-white/50 backdrop-blur-sm",
                "focus:outline-none focus:ring-2 focus:ring-turquoise-500 focus:border-transparent",
                "transition-all duration-200",
                if(Map.get(@form_errors, :custom_meeting_url),
                  do: "border-red-300 text-red-900 placeholder-red-300",
                  else: "border-purple-200/50 text-neutral-700 placeholder-neutral-400"
                )
              ]}
              placeholder="https://meet.example.com/room123"
            />
          </div>
          <%= if error = Map.get(@form_errors, :custom_meeting_url) do %>
            <p class="mt-1 text-sm text-red-600 flex items-center">
              <svg class="w-4 h-4 mr-1" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
              {error}
            </p>
          <% else %>
            <p class="mt-2 text-xs text-neutral-500">
              Enter the complete URL for your video meeting room
            </p>
          <% end %>
        </div>
        
    <!-- Warning Card -->
        <div class="glass-card p-4 bg-gradient-to-r from-amber-50/50 to-yellow-50/50 border border-amber-200/30">
          <div class="flex items-start space-x-3">
            <div class="w-8 h-8 rounded-lg bg-amber-100 flex items-center justify-center flex-shrink-0">
              <svg
                class="w-4 h-4 text-amber-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3l-7.268-14c-.77-1.333-1.964-1.333-2.732 0l-7.268 14c-.77 1.333.192 3 1.732 3z"
                />
              </svg>
            </div>
            <div class="flex-1">
              <h4 class="text-sm font-semibold text-amber-800 mb-1">Important Note</h4>
              <p class="text-sm text-neutral-600">
                This URL will be included directly in meeting invitations and confirmation emails.
                Please ensure the link is valid and accessible to all participants. If the URL
                is incorrect or unavailable, attendees will not be able to join the meeting.
              </p>
            </div>
          </div>
        </div>

        <%= if error = Map.get(@form_errors, :base) do %>
          <div class="glass-card p-3 bg-red-50/50 border border-red-200/50">
            <p class="text-sm text-red-600 flex items-center">
              <svg class="w-4 h-4 mr-2" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7 4a1 1 0 11-2 0 1 1 0 012 0zm-1-9a1 1 0 00-1 1v4a1 1 0 102 0V6a1 1 0 00-1-1z"
                  clip-rule="evenodd"
                />
              </svg>
              {error}
            </p>
          </div>
        <% end %>

        <div class="flex justify-end pt-4">
          <UIComponents.form_submit_button saving={@saving} />
        </div>
      </form>
    </div>
    """
  end

  # Function component for custom video info section
  defp custom_video_info(assigns) do
    ~H"""
    <div class="mb-6">
      <p class="text-gray-600 mb-4">
        Use this option to integrate any video conferencing platform that provides static meeting room URLs.
      </p>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <!-- Compatible Platforms Card -->
        <div class="glass-card p-4 bg-gradient-to-br from-turquoise-50/50 to-blue-50/50">
          <div class="flex items-start space-x-3">
            <div class="w-8 h-8 rounded-lg bg-turquoise-100 flex items-center justify-center flex-shrink-0">
              <svg
                class="w-4 h-4 text-turquoise-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
            <div>
              <p class="text-sm font-semibold text-turquoise-800 mb-2">Compatible with</p>
              <ul class="text-sm text-neutral-600 space-y-1">
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> Jitsi Meet
                </li>
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> BigBlueButton
                </li>
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> Custom meeting rooms
                </li>
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> Any static video URL
                </li>
              </ul>
            </div>
          </div>
        </div>
        
    <!-- How It Works Card -->
        <div class="glass-card p-4 bg-gradient-to-br from-purple-50/50 to-indigo-50/50">
          <div class="flex items-start space-x-3">
            <div class="w-8 h-8 rounded-lg bg-purple-100 flex items-center justify-center flex-shrink-0">
              <svg
                class="w-4 h-4 text-purple-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
            </div>
            <div>
              <p class="text-sm font-semibold text-purple-800 mb-2">How it works</p>
              <ul class="text-sm text-neutral-600 space-y-1">
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">•</span> You provide a fixed meeting URL
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">•</span> All meetings use this same link
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">•</span> URL included in email invitations
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">•</span> No automatic room creation
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
