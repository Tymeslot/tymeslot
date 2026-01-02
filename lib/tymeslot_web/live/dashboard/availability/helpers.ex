defmodule TymeslotWeb.Dashboard.Availability.Helpers do
  @moduledoc """
  Shared helper functions for availability components.
  Provides timezone formatting and display utilities.
  """

  use Phoenix.Component

  alias Tymeslot.Utils.TimezoneUtils
  import TymeslotWeb.Components.FlagHelpers

  @doc """
  Extracts and formats timezone information from a user profile.
  Returns a map with formatted timezone display and country code.
  """
  @spec get_timezone_info(Ecto.Schema.t() | nil) :: %{
          timezone: String.t(),
          timezone_display: String.t(),
          country_code: String.t() | nil
        }
  def get_timezone_info(profile) do
    timezone = if profile, do: profile.timezone, else: "UTC"

    %{
      timezone: timezone,
      timezone_display: TimezoneUtils.format_timezone(timezone),
      country_code: TimezoneUtils.get_country_code_for_timezone(timezone)
    }
  end

  @doc """
  Renders a timezone display with country flag and formatted timezone name.
  """
  @spec timezone_display(map()) :: Phoenix.LiveView.Rendered.t()
  def timezone_display(assigns) do
    ~H"""
    <div class="flex items-center space-x-2 text-sm text-gray-600">
      <.safe_flag
        country_code={@country_code}
        class="w-4 h-3 flex-shrink-0 rounded-sm shadow-sm"
        fallback_icon="🌐"
        show_fallback={true}
      />
      <span>{@timezone_display}</span>
    </div>
    """
  end
end
