defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.MirotalkConfig do
  @moduledoc """
  Component for configuring MiroTalk P2P video integration.
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
                d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"
              />
            </svg>
          </div>
          <h3 class="text-lg font-semibold text-gray-800">Setup MiroTalk P2P</h3>
        </div>
        <UIComponents.close_button target={@target} />
      </div>
      
    <!-- Info Section -->
      <.mirotalk_info />

      <div class="border-t border-purple-200/30 my-6"></div>
      
    <!-- Configuration Form with Glass Morphism -->
      <form phx-submit="add_integration" phx-target={@target} class="space-y-6">
        <input type="hidden" name="integration[provider]" value="mirotalk" />
        
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
              placeholder="My MiroTalk P2P"
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
        
    <!-- API Key Field with Toggle -->
        <div>
          <label for="integration_api_key" class="block text-sm font-semibold text-neutral-700 mb-2">
            API Key
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
                  d="M15 7a2 2 0 012 2m4 0a6 6 0 01-7.743 5.743L11 17H9v2H7v2H4a1 1 0 01-1-1v-2.586a1 1 0 01.293-.707l5.964-5.964A6 6 0 1121 9z"
                />
              </svg>
            </div>
            <input
              type="password"
              id="integration_api_key"
              name="integration[api_key]"
              value={Map.get(@form_values, "api_key", "")}
              phx-blur="validate_field"
              phx-value-field="api_key"
              phx-target={@target}
              required
              class={[
                "w-full pl-10 pr-3 py-2.5 border rounded-lg",
                "bg-white/50 backdrop-blur-sm",
                "focus:outline-none focus:ring-2 focus:ring-turquoise-500 focus:border-transparent",
                "transition-all duration-200",
                if(Map.get(@form_errors, :api_key),
                  do: "border-red-300 text-red-900 placeholder-red-300",
                  else: "border-purple-200/50 text-neutral-700 placeholder-neutral-400"
                )
              ]}
              placeholder="Your API key"
            />
          </div>
          <%= if error = Map.get(@form_errors, :api_key) do %>
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
              Get your API key from your MiroTalk instance configuration
            </p>
          <% end %>
        </div>
        
    <!-- Base URL Field -->
        <div>
          <label for="integration_base_url" class="block text-sm font-semibold text-neutral-700 mb-2">
            Base URL
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
                  d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"
                />
              </svg>
            </div>
            <input
              type="url"
              id="integration_base_url"
              name="integration[base_url]"
              value={Map.get(@form_values, "base_url", "")}
              phx-blur="validate_field"
              phx-value-field="base_url"
              phx-target={@target}
              required
              class={[
                "w-full pl-10 pr-3 py-2.5 border rounded-lg",
                "bg-white/50 backdrop-blur-sm",
                "focus:outline-none focus:ring-2 focus:ring-turquoise-500 focus:border-transparent",
                "transition-all duration-200",
                if(Map.get(@form_errors, :base_url),
                  do: "border-red-300 text-red-900 placeholder-red-300",
                  else: "border-purple-200/50 text-neutral-700 placeholder-neutral-400"
                )
              ]}
              placeholder="https://meet.example.com"
            />
          </div>
          <%= if error = Map.get(@form_errors, :base_url) do %>
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
              The full URL where your MiroTalk P2P instance is hosted
            </p>
          <% end %>
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

  # Function component for MiroTalk info section
  defp mirotalk_info(assigns) do
    ~H"""
    <div class="mb-6">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <!-- Features Card -->
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
              <p class="text-sm font-semibold text-turquoise-800 mb-2">Features</p>
              <ul class="text-sm text-neutral-600 space-y-1">
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> No intermediary servers
                </li>
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> End-to-end encryption
                </li>
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> Screen sharing support
                </li>
                <li class="flex items-center">
                  <span class="text-turquoise-500 mr-1">✓</span> File sharing
                </li>
              </ul>
            </div>
          </div>
        </div>
        
    <!-- Requirements Card -->
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
                  d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
                />
              </svg>
            </div>
            <div>
              <p class="text-sm font-semibold text-purple-800 mb-2">Requirements</p>
              <ul class="text-sm text-neutral-600 space-y-1">
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">•</span> Self-hosted MiroTalk instance
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">•</span> API key from your instance
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">•</span> Base URL of your server
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Note Card -->
      <div class="glass-card p-4 bg-gradient-to-r from-amber-50/50 to-yellow-50/50 border border-amber-200/30">
        <div class="flex items-start space-x-3">
          <div class="w-8 h-8 rounded-lg bg-amber-100 flex items-center justify-center flex-shrink-0">
            <svg class="w-4 h-4 text-amber-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
          </div>
          <div class="flex-1">
            <p class="text-sm font-semibold text-amber-800 mb-1">Important Note</p>
            <p class="text-sm text-neutral-600">
              You need to deploy your own MiroTalk P2P instance. Visit the
              <a
                href="https://github.com/miroslavpejic85/mirotalk"
                target="_blank"
                class="text-turquoise-600 hover:text-turquoise-500 underline font-medium"
              >
                official GitHub repository
              </a>
              for deployment instructions.
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
