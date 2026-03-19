defmodule TymeslotWeb.Components.FlagHelpers do
  @moduledoc """
  Helper components for rendering country flags with fallback support.
  Provides safe flag rendering that won't crash if a flag doesn't exist.
  """

  use Phoenix.Component
  require Logger

  alias Phoenix.LiveView.TagEngine
  alias Tymeslot.Timezones

  @doc """
  Renders a country flag with automatic fallback if the flag doesn't exist.
  Logs a warning when a flag is missing to help identify unsupported countries.

  ## Examples

      <.safe_flag country_code={:usa} class="w-6 h-4" />
      <.safe_flag country_code={:dza} class="w-6 h-4" />  # Will show fallback
  """
  attr :country_code, :atom, required: true
  attr :class, :string, default: ""
  attr :fallback_icon, :string, default: "🌍"
  attr :show_fallback, :boolean, default: true

  @spec safe_flag(map()) :: Phoenix.LiveView.Rendered.t()
  def safe_flag(assigns) do
    if Timezones.flag_exists?(assigns.country_code) do
      flag_function = Function.capture(Flagpack, assigns.country_code, 1)
      flag_html = TagEngine.component(flag_function, %{class: assigns.class}, __ENV__)
      assigns = assign(assigns, :flag_html, flag_html)

      ~H"""
      {@flag_html}
      """
    else
      # Log missing flag for monitoring
      if assigns.country_code do
        Logger.warning("Missing flag for country code",
          country_code: inspect(assigns.country_code)
        )
      end

      if assigns.show_fallback do
        ~H"""
        <span class={["inline-flex items-center justify-center", @class]} title="Flag not available">
          {@fallback_icon}
        </span>
        """
      else
        ~H"""
        <!-- No flag available -->
        """
      end
    end
  end

  @doc """
  Renders a flag for a timezone, automatically looking up the country code.
  Falls back gracefully if the timezone has no associated country or flag.

  ## Examples

      <.timezone_flag timezone="America/New_York" class="w-6 h-4" />
      <.timezone_flag timezone="Africa/Algiers" class="w-6 h-4" />  # Will show fallback
  """
  attr :timezone, :string, required: true
  attr :class, :string, default: ""
  attr :fallback_icon, :string, default: "🌍"
  attr :show_fallback, :boolean, default: true

  @spec timezone_flag(map()) :: Phoenix.LiveView.Rendered.t()
  def timezone_flag(assigns) do
    country_code = Timezones.country_code(assigns.timezone)

    assigns = assign(assigns, :country_code, country_code)

    ~H"""
    <.safe_flag
      country_code={@country_code}
      class={@class}
      fallback_icon={@fallback_icon}
      show_fallback={@show_fallback}
    />
    """
  end

  @doc """
  Renders a flag for a language locale code.
  Maps locale codes to appropriate country flags for language selection UI.

  ## Examples

      <.locale_flag locale="en" class="w-5 h-4" />
      <.locale_flag locale="de" class="w-5 h-4" />
      <.locale_flag locale="uk" class="w-5 h-4" />
  """
  attr :locale, :string, required: true
  attr :class, :string, default: ""
  attr :show_fallback, :boolean, default: true

  @spec locale_flag(map()) :: Phoenix.LiveView.Rendered.t()
  def locale_flag(assigns) do
    country_code = locale_to_country_code(assigns.locale)
    assigns = assign(assigns, :country_code, country_code)

    ~H"""
    <.safe_flag
      country_code={@country_code}
      class={@class}
      show_fallback={@show_fallback}
    />
    """
  end

  defp locale_to_country_code("en"), do: :gbr
  defp locale_to_country_code("de"), do: :deu
  defp locale_to_country_code("uk"), do: :ukr
  defp locale_to_country_code("fr"), do: :fra
  defp locale_to_country_code(_locale), do: nil

  @doc """
  Sanitizes a CSS class name to prevent XSS — only allows alphanumeric
  characters, hyphens, and underscores, and truncates to 100 characters.
  """
  @spec sanitize_css_class(String.t()) :: String.t()
  def sanitize_css_class(class_name) do
    class_name
    |> String.replace(~r/[^a-zA-Z0-9\-_]/, "")
    |> String.slice(0, 100)
  end
end
