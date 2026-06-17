defmodule TymeslotWeb.Components.TimezoneDropdown do
  @moduledoc """
  Shared timezone dropdown component with flag support and search functionality.
  Used across onboarding and settings pages with configurable styling and event handling.
  """

  use Phoenix.Component

  import TymeslotWeb.Components.CoreComponents

  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Shared.TimezoneHelpers

  attr :profile, :map, required: true
  attr :timezone_options, :list, default: []
  attr :timezone_dropdown_open, :boolean, default: false
  attr :timezone_search, :string, default: ""
  attr :target, :any, default: nil, doc: "LiveComponent target for phx-target attribute"

  attr :safe_flags, :boolean,
    default: false,
    doc: "Whether to use safe flag rendering (for onboarding)"

  attr :class, :string, default: "", doc: "Additional CSS classes for the container"

  @spec timezone_dropdown(map()) :: Phoenix.LiveView.Rendered.t()
  def timezone_dropdown(assigns) do
    ~H"""
    <div class={["relative", @class]}>
      <label class="label text-tymeslot-700 mb-3 block">
        <div class="flex items-center gap-2">
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
            />
          </svg>
          Your Timezone
        </div>
      </label>

      <.dropdown
        id="timezone-dropdown"
        open={@timezone_dropdown_open}
        on_toggle="toggle_timezone_dropdown"
        on_close="close_timezone_dropdown"
        target={@target}
        position={:top_start}
        role="dialog"
        panel_label="Select timezone"
        trigger_class="group relative cursor-pointer z-50 w-full text-left"
        class="right-0 max-h-64 brand-card rounded-xl shadow-lg border border-white/30 overflow-hidden"
        aria-label="Select timezone"
      >
        <:trigger>
          <div class="input p-4 hover:bg-white transition-all duration-200">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3 flex-1 min-w-0">
                <%= if country_code = Timezones.country_code((@profile && @profile.timezone) || "UTC") do %>
                  <.timezone_flag
                    country_code={country_code}
                    safe_mode={@safe_flags}
                    class="w-6 h-4 shrink-0 rounded-sm shadow-sm"
                  />
                <% end %>
                <div class="flex-1 min-w-0">
                  <div class="text-sm font-medium text-tymeslot-800 truncate">
                    {Timezones.format((@profile && @profile.timezone) || "UTC")}
                  </div>
                  <div class="text-xs mt-1 text-tymeslot-600">
                    {TimezoneHelpers.format_local_time((@profile && @profile.timezone) || "UTC")} local time
                  </div>
                </div>
              </div>
              <div class="flex items-center gap-2 ml-3">
                <div class="text-sm px-3 py-1.5 rounded-full bg-tymeslot-100 text-tymeslot-700 font-medium">
                  {get_timezone_offset((@profile && @profile.timezone) || "UTC")}
                </div>
                <svg
                  class={"w-4 h-4 transition-transform duration-200 text-tymeslot-500 #{if @timezone_dropdown_open, do: "rotate-180", else: "rotate-0"}"}
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M19 9l-7 7-7-7"
                  />
                </svg>
              </div>
            </div>
          </div>
        </:trigger>
        <:panel>
          <div class="p-3 border-b border-white/20">
            <div class="relative">
              <input
                id="timezone-search"
                type="text"
                phx-keyup="search_timezone"
                phx-target={@target}
                name="value"
                value={@timezone_search || ""}
                placeholder="Search cities, countries, or timezones..."
                class="w-full px-4 py-2 rounded-lg text-sm border-0 pr-10 focus:outline-hidden focus:ring-2 focus:ring-teal-400/30 bg-white/90 text-tymeslot-800"
                autocomplete="off"
                phx-hook="AutoFocus"
              />
              <div class="absolute right-3 top-1/2 transform -translate-y-1/2 pointer-events-none">
                <svg
                  class="w-4 h-4 text-tymeslot-500"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                  />
                </svg>
              </div>
            </div>
          </div>
          <div class="max-h-48 overflow-y-auto">
            <div class="p-1">
              <%= for {label, value, offset} <- Timezones.search(@timezone_search || "") do %>
                <div
                  phx-click="change_timezone"
                  phx-value-timezone={value}
                  phx-target={@target}
                  class="w-full text-left px-3 py-2.5 text-sm rounded-lg cursor-pointer transition-all duration-200 hover:bg-cyan-50 hover:shadow-sm border border-transparent hover:border-cyan-200"
                >
                  <div class="flex items-center gap-3 flex-1 min-w-0">
                    <%= if country_code = Timezones.country_code(value) do %>
                      <.timezone_flag
                        country_code={country_code}
                        safe_mode={@safe_flags}
                        class="w-5 h-3 shrink-0 rounded-sm shadow-sm"
                      />
                    <% end %>
                    <div class="flex-1 min-w-0">
                      <div class="font-medium truncate text-tymeslot-800">{label}</div>
                      <div class="text-xs mt-0.5 text-tymeslot-600">
                        {TimezoneHelpers.format_local_time(value)} local time • {offset}
                      </div>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </:panel>
      </.dropdown>

      <p class="mt-2 text-sm text-tymeslot-600">
        This timezone will be used for your availability and scheduling.
      </p>
    </div>
    """
  end

  # Private components and helper functions

  defp timezone_flag(assigns) do
    # Use safe flag component that handles ID conflicts
    ~H"""
    <TymeslotWeb.Components.FlagHelpers.safe_flag
      country_code={@country_code}
      class={@class}
      show_fallback={not @safe_mode}
    />
    """
  end

  defp get_timezone_offset(timezone) do
    Timezones.utc_offset(timezone)
  end
end
