defmodule TymeslotWeb.Dashboard.CalendarSettings.Helpers do
  @moduledoc """
  Helper functions for calendar settings dashboard.
  """
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.DisplayHelpers

  @spec format_provider_name(String.t() | atom()) :: String.t()
  def format_provider_name(provider) do
    DisplayHelpers.format_provider_display_name(provider)
  end

  @spec needs_scope_upgrade?(map()) :: boolean()
  def needs_scope_upgrade?(integration) do
    Calendar.needs_scope_upgrade?(integration)
  end
end
