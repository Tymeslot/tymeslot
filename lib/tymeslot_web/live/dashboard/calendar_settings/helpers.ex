defmodule TymeslotWeb.Dashboard.CalendarSettings.Helpers do
  @moduledoc """
  Helper functions for calendar settings dashboard.
  """
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @spec format_provider_name(String.t() | atom()) :: String.t()
  def format_provider_name(provider) do
    Calendar.format_provider_display_name(provider)
  end

  @spec format_token_expiry(map()) :: String.t()
  def format_token_expiry(integration) do
    Calendar.format_token_expiry(integration)
  end

  @spec needs_scope_upgrade?(map()) :: boolean()
  def needs_scope_upgrade?(integration) do
    Calendar.needs_scope_upgrade?(integration)
  end

  @doc """
  Centralized provider metadata for rendering provider cards.
  Queries ProviderConfig as single source of truth.
  """
  @spec provider_card_info(atom()) :: map()
  def provider_card_info(provider) when is_atom(provider) do
    %{
      provider: Atom.to_string(provider),
      click: ProviderConfig.click_event(provider),
      btn: ProviderConfig.button_text(provider),
      desc: ProviderConfig.description(provider)
    }
  end

  @doc """
  Helper to extract a friendly display name from a calendar
  Handles the case where Radicale calendars may have UUIDs as names
  """
  @spec extract_calendar_display_name(map()) :: String.t()
  def extract_calendar_display_name(calendar) do
    Calendar.extract_calendar_display_name(calendar)
  end
end
