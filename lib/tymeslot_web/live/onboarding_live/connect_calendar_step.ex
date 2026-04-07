defmodule TymeslotWeb.OnboardingLive.ConnectCalendarStep do
  @moduledoc """
  Calendar connection step component for the onboarding flow.

  Supports three states:
  - Provider selection (Google, Outlook, CalDAV)
  - Inline CalDAV credential form
  - Connected calendar list with option to add more
  """

  use Phoenix.Component
  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Renders the calendar connection step.

  ## Attributes

  * `calendar_state` - Current state atom (`:selecting` or `:connecting_caldav`)
  * `connected_calendars` - List of connected calendar integrations
  * `caldav_form_data` - CalDAV form field values
  * `caldav_form_errors` - CalDAV form validation errors
  """
  attr :calendar_state, :atom, required: true
  attr :connected_calendars, :list, required: true
  attr :caldav_form_data, :map, required: true
  attr :caldav_form_errors, :map, required: true

  @spec connect_calendar_step(map()) :: Phoenix.LiveView.Rendered.t()
  def connect_calendar_step(assigns) do
    ~H"""
    <div>
      <%= case @calendar_state do %>
        <% :adding -> %>
          <.provider_selection />
        <% :connecting_caldav -> %>
          <.caldav_form
            caldav_form_data={@caldav_form_data}
            caldav_form_errors={@caldav_form_errors}
          />
        <% _selecting -> %>
          <%= if @connected_calendars != [] do %>
            <.connected_view connected_calendars={@connected_calendars} />
          <% else %>
            <.provider_selection />
          <% end %>
      <% end %>
    </div>
    """
  end

  defp provider_selection(assigns) do
    ~H"""
    <div class="onboarding-provider-cards">
      <button type="button" phx-click="connect_google_calendar" class="onboarding-provider-card">
        <div class="onboarding-provider-icon flex items-center justify-center rounded-lg bg-blue-50">
          <.icon name="hero-calendar-days" class="w-5 h-5 text-blue-600" />
        </div>
        <div>
          <div class="onboarding-provider-name">Google Calendar</div>
          <div class="onboarding-provider-label">Connect via OAuth — takes seconds</div>
        </div>
      </button>

      <button type="button" phx-click="connect_outlook_calendar" class="onboarding-provider-card">
        <div class="onboarding-provider-icon flex items-center justify-center rounded-lg bg-cyan-50">
          <.icon name="hero-calendar" class="w-5 h-5 text-cyan-600" />
        </div>
        <div>
          <div class="onboarding-provider-name">Outlook Calendar</div>
          <div class="onboarding-provider-label">Connect via OAuth — takes seconds</div>
        </div>
      </button>

      <button type="button" phx-click="show_caldav_form" class="onboarding-provider-card">
        <div class="onboarding-provider-icon flex items-center justify-center rounded-lg bg-tymeslot-100">
          <.icon name="hero-server" class="w-5 h-5 text-tymeslot-600" />
        </div>
        <div>
          <div class="onboarding-provider-name">CalDAV</div>
          <div class="onboarding-provider-label">Nextcloud, Radicale, or any CalDAV server</div>
        </div>
      </button>
    </div>
    """
  end

  defp caldav_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      as={:caldav}
      phx-change="validate_caldav"
      phx-submit="discover_caldav_calendars"
      class="onboarding-form"
      id="caldav-form"
    >
      <div class="onboarding-form-group">
        <label for="caldav_url" class="label">Server URL</label>
        <input
          type="url"
          id="caldav_url"
          name="url"
          value={Map.get(@caldav_form_data, "url", "")}
          class={[
            "input",
            if(FormValidationHelpers.field_errors(@caldav_form_errors, :url) != [],
              do: "input-error"
            )
          ]}
          placeholder="https://cloud.example.com/remote.php/dav"
        />
        <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :url) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <div class="onboarding-form-group">
        <label for="caldav_username" class="label">Username</label>
        <input
          type="text"
          id="caldav_username"
          name="username"
          value={Map.get(@caldav_form_data, "username", "")}
          class={[
            "input",
            if(FormValidationHelpers.field_errors(@caldav_form_errors, :username) != [],
              do: "input-error"
            )
          ]}
          placeholder="your-username"
        />
        <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :username) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <div class="onboarding-form-group">
        <label for="caldav_password" class="label">Password</label>
        <input
          type="password"
          id="caldav_password"
          name="password"
          value={Map.get(@caldav_form_data, "password", "")}
          class={[
            "input",
            if(FormValidationHelpers.field_errors(@caldav_form_errors, :password) != [],
              do: "input-error"
            )
          ]}
          placeholder="App password or token"
        />
        <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :password) do %>
          <p class="mt-2 text-token-sm text-red-600 font-bold">{message}</p>
        <% end %>
      </div>

      <%= for message <- FormValidationHelpers.field_errors(@caldav_form_errors, :discovery) do %>
        <p class="text-token-sm text-red-600 font-bold">{message}</p>
      <% end %>

      <div class="flex gap-3">
        <button type="button" phx-click="cancel_caldav" class="btn-secondary px-5 py-2.5">
          Cancel
        </button>
        <button type="submit" class="btn-primary px-5 py-2.5 flex-1">
          Discover calendars
        </button>
      </div>
    </.form>
    """
  end

  defp connected_view(assigns) do
    ~H"""
    <div class="space-y-3">
      <%= for calendar <- @connected_calendars do %>
        <div class="onboarding-connected-calendar">
          <.icon name="hero-check-circle-solid" class="w-5 h-5 text-green-600 shrink-0" />
          <div class="flex-1 min-w-0">
            <div class="text-token-base font-bold text-tymeslot-800 truncate">
              {calendar.name}
            </div>
            <div class="text-token-sm text-tymeslot-400">
              {String.capitalize(calendar.provider)}
            </div>
          </div>
        </div>
      <% end %>

      <button type="button" phx-click="add_another_calendar" class="onboarding-add-calendar-btn w-full">
        <.icon name="hero-plus" class="w-4 h-4" />
        Add another calendar
      </button>
    </div>
    """
  end
end
