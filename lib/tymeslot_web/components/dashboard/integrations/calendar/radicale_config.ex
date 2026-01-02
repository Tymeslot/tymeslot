defmodule TymeslotWeb.Components.Dashboard.Integrations.Calendar.RadicaleConfig do
  @moduledoc """
  LiveComponent for configuring Radicale calendar integration.

  Radicale is a lightweight CalDAV server with simple configuration.
  This component provides a user-friendly interface specifically for Radicale servers.
  """
  use TymeslotWeb.Components.Dashboard.Integrations.Calendar.ConfigBase,
    provider: :radicale,
    default_name: "Radicale Calendar"

  alias TymeslotWeb.Components.Dashboard.Integrations.Calendar.SharedFormComponents,
    as: SharedForm

  alias TymeslotWeb.Components.Dashboard.Integrations.Shared.UIComponents

  @impl true
  def render(assigns) do
    # Ensure all required assigns have default values
    assigns = assign_config_defaults(assigns)

    ~H"""
    <div class="relative">
      <!-- Header with Close Button -->
      <div class="flex items-center justify-between mb-6">
        <div class="flex items-center">
          <div class="text-turquoise-600 mr-3">
            <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 3v4M3 5h4M6 17v4m-2-2h4m5-16l2.286 6.857L21 12l-5.714 2.143L13 21l-2.286-6.857L5 12l5.714-2.143L13 3z"
              />
            </svg>
          </div>
          <h3 class="text-lg font-semibold text-gray-800">Setup Radicale Calendar</h3>
        </div>
        <UIComponents.close_button target={@target} />
      </div>
      
    <!-- Instructions Section -->
      <.radicale_instructions />

      <div class="border-t border-turquoise-200/30 my-6"></div>

      <%= if @show_calendar_selection do %>
        <!-- Calendar Selection Form -->
        <form phx-submit="add_integration" phx-target={@target} class="space-y-6">
          <SharedForm.integration_name_field
            form_errors={@form_errors}
            suggested_name={get_suggested_integration_name(assigns)}
            placeholder="My Radicale Calendar"
          />

          <input type="hidden" name="integration[provider]" value="radicale" />

          <SharedForm.calendar_selection discovered_calendars={@discovered_calendars} />
          
    <!-- Hidden fields for discovered credentials -->
          <input type="hidden" name="integration[url]" value={@discovery_credentials[:url]} />
          <input type="hidden" name="integration[username]" value={@discovery_credentials[:username]} />
          <input type="hidden" name="integration[password]" value={@discovery_credentials[:password]} />

          <%= if error = Map.get(@form_errors, :base) do %>
            <SharedForm.error_banner error={error} />
          <% end %>

          <div class="flex justify-end mt-6 pt-4 border-t border-turquoise-200/30">
            <UIComponents.form_submit_button saving={@saving} />
          </div>
        </form>
      <% else %>
        <!-- Discovery Form -->
        <form
          phx-submit="discover_calendars"
          phx-change="track_form_change"
          phx-target={@myself}
          class="space-y-6"
        >
          <input type="hidden" name="integration[provider]" value="radicale" />
          
    <!-- Form fields in 2x2 grid layout -->
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <!-- Integration Name -->
            <div>
              <label for="integration_name" class="label">
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
                  value={Map.get(@form_values || %{}, "name", "")}
                  required
                  phx-blur="validate_field"
                  phx-value-field="name"
                  phx-target={@myself}
                  class={[
                    "glass-input pl-10 w-full",
                    if(Map.get(@form_errors, :name), do: "input-error", else: "")
                  ]}
                  placeholder="My Radicale"
                />
              </div>
              <%= if error = Map.get(@form_errors, :name) do %>
                <p class="form-error">{error}</p>
              <% end %>
            </div>
            
    <!-- Server URL -->
            <div>
              <label for="discovery_url" class="label">
                Server URL
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
                      d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 919-9"
                    />
                  </svg>
                </div>
                <input
                  type="text"
                  id="discovery_url"
                  name="integration[url]"
                  value={Map.get(@form_values || %{}, "url", "")}
                  required
                  class="glass-input pl-10 w-full"
                  placeholder="radicale.example.com:5232"
                />
              </div>
            </div>
            
    <!-- Username -->
            <div>
              <label for="discovery_username" class="label">
                Username
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
                      d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"
                    />
                  </svg>
                </div>
                <input
                  type="text"
                  id="discovery_username"
                  name="integration[username]"
                  value={Map.get(@form_values || %{}, "username", "")}
                  required
                  class="glass-input pl-10 w-full"
                  placeholder="Your username"
                />
              </div>
            </div>
            
    <!-- Password -->
            <div>
              <label for="discovery_password" class="label">
                Password
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
                  id="discovery_password"
                  name="integration[password]"
                  value={Map.get(@form_values || %{}, "password", "")}
                  required
                  class="glass-input pl-10 w-full"
                  placeholder="Your password"
                />
              </div>
            </div>
          </div>

          <%= if error = Map.get(@form_errors, :discovery) do %>
            <p class="form-error">{error}</p>
          <% end %>

          <button
            type="submit"
            phx-disable-with="Discovering calendars..."
            disabled={@saving}
            class="btn btn-primary w-full"
          >
            <%= if @saving do %>
              <span class="flex items-center justify-center">
                <UIComponents.loading_spinner class="h-4 w-4 mr-2" /> Discovering calendars...
              </span>
            <% else %>
              <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
              Discover My Calendars
            <% end %>
          </button>

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
        </form>
      <% end %>
    </div>
    """
  end

  # Function component for Radicale instructions
  defp radicale_instructions(assigns) do
    ~H"""
    <div class="mb-6">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <!-- Setup Steps Card -->
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
                  d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
                />
              </svg>
            </div>
            <div>
              <p class="text-sm font-semibold text-turquoise-800 mb-2">Setup Steps</p>
              <ul class="text-sm text-neutral-600 space-y-1">
                <li class="flex items-start">
                  <span class="text-turquoise-500 mr-1">1.</span> Find your Radicale URL
                </li>
                <li class="flex items-start">
                  <span class="text-turquoise-500 mr-1">2.</span> Get your username
                </li>
                <li class="flex items-start">
                  <span class="text-turquoise-500 mr-1">3.</span> Enter your password
                </li>
                <li class="flex items-start">
                  <span class="text-turquoise-500 mr-1">4.</span> Auto-discover calendars
                </li>
              </ul>
            </div>
          </div>
        </div>
        
    <!-- Features Card -->
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
                  d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
            <div>
              <p class="text-sm font-semibold text-purple-800 mb-2">Features</p>
              <ul class="text-sm text-neutral-600 space-y-1">
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">✓</span> Lightweight & fast
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">✓</span> Low resource usage
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">✓</span> Easy self-hosting
                </li>
                <li class="flex items-center">
                  <span class="text-purple-500 mr-1">✓</span> Standard CalDAV
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
      
    <!-- Pro Tip Card -->
      <div class="glass-card p-4 bg-gradient-to-r from-amber-50/50 to-yellow-50/50 border border-amber-200/30 mt-4">
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
            <p class="text-sm font-semibold text-amber-800 mb-1">Pro Tip</p>
            <p class="text-sm text-neutral-600">
              Radicale typically runs on port 5232. If you're self-hosting, make sure to include the port
              in your server URL (e.g., radicale.example.com:5232). We'll automatically discover all your
              calendars and let you choose which ones to sync.
              <a
                href="https://radicale.org/v3.html"
                target="_blank"
                class="text-turquoise-600 hover:text-turquoise-500 underline font-medium ml-1"
              >
                Learn more about Radicale →
              </a>
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
