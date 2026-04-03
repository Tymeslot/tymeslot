defmodule Tymeslot.Emails.Shared.SharedHelpers do
  @moduledoc """
  Shared helper functions for email templates.
  Centralizes common formatting and utility functions used across all email templates.
  """

  alias Phoenix.HTML
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Helpers.LocaleFormat

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Formats a date into a full readable format.
  Example: "November 25, 2024"
  """
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_date(%Date{} = date) do
    Calendar.strftime(date, "%B %d, %Y")
  end

  def format_date(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> format_date()
  end

  def format_date(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> format_date()
  end

  @doc """
  Formats a date according to locale conventions.
  Delegates to LocaleFormat for locale-aware formatting.
  """
  @spec format_date(Date.t() | DateTime.t() | NaiveDateTime.t(), String.t()) :: String.t()
  def format_date(%Date{} = date, locale), do: LocaleFormat.format_date(date, locale)

  def format_date(%DateTime{} = datetime, locale) do
    datetime |> DateTime.to_date() |> format_date(locale)
  end

  def format_date(%NaiveDateTime{} = datetime, locale) do
    datetime |> NaiveDateTime.to_date() |> format_date(locale)
  end

  @doc """
  Formats a date into a short readable format.
  Example: "Nov 25"
  """
  @spec format_date_short(Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_date_short(%Date{} = date) do
    "#{Calendar.strftime(date, "%b")} #{date.day}"
  end

  def format_date_short(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_date()
    |> format_date_short()
  end

  def format_date_short(%NaiveDateTime{} = datetime) do
    datetime
    |> NaiveDateTime.to_date()
    |> format_date_short()
  end

  @doc """
  Formats a date into a short locale-aware format.
  English: "Nov 25", others: "25.11."
  """
  @spec format_date_short(Date.t() | DateTime.t() | NaiveDateTime.t(), String.t()) :: String.t()
  def format_date_short(%Date{} = date, "en"), do: "#{Calendar.strftime(date, "%b")} #{date.day}"
  def format_date_short(%Date{} = date, "fr"), do: "#{date.day}/#{date.month}"
  def format_date_short(%Date{} = date, _locale), do: "#{date.day}.#{date.month}."

  def format_date_short(%DateTime{} = datetime, locale) do
    datetime |> DateTime.to_date() |> format_date_short(locale)
  end

  def format_date_short(%NaiveDateTime{} = datetime, locale) do
    datetime |> NaiveDateTime.to_date() |> format_date_short(locale)
  end

  @doc """
  Formats a time with timezone.
  Example: "02:30 PM PST"
  """
  @spec format_time(DateTime.t()) :: String.t()
  def format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%I:%M %p %Z")
  end

  @doc """
  Formats a time with timezone, locale-aware.
  Example (en): "02:30 PM PST", (de): "14:30 PST"
  """
  @spec format_time(DateTime.t(), String.t()) :: String.t()
  def format_time(%DateTime{} = datetime, locale) do
    time = DateTime.to_time(datetime)
    tz = Calendar.strftime(datetime, "%Z")
    "#{LocaleFormat.format_time(time, locale)} #{tz}"
  end

  @doc """
  Formats a time range.
  Example: "02:30 PM - 03:00 PM PST"
  """
  @spec format_time_range(DateTime.t(), DateTime.t()) :: String.t()
  def format_time_range(%DateTime{} = start_time, %DateTime{} = end_time) do
    start_str = Calendar.strftime(start_time, "%I:%M %p")
    end_str = Calendar.strftime(end_time, "%I:%M %p %Z")
    "#{start_str} - #{end_str}"
  end

  @doc """
  Formats a complete datetime.
  Example: "November 25, 2024 at 2:30 PM PST"
  """
  @spec format_datetime(DateTime.t()) :: String.t()
  def format_datetime(%DateTime{} = datetime) do
    "#{format_date(datetime)} at #{format_time(datetime)}"
  end

  @doc """
  Gets the application URL from configuration.
  """
  @spec get_app_url() :: String.t()
  def get_app_url do
    Endpoint.url()
  end

  @doc """
  Builds a full URL for a given path.
  """
  @spec build_url(String.t()) :: String.t()
  def build_url(path) do
    "#{get_app_url()}#{path}"
  end

  @doc """
  Formats a meeting duration.
  Example: "30 minutes" or "1 hour"
  """
  @spec format_duration(integer() | String.t()) :: String.t()
  def format_duration(duration) do
    DateTimeUtils.format_duration(duration)
  end

  @doc """
  Formats a meeting duration in a locale-aware way.
  Example (en): "30 minutes", "1 hour"; (de): "30 Minuten", "1 Stunde"
  """
  @spec format_duration(integer() | String.t(), String.t()) :: String.t()
  def format_duration(duration, locale) do
    minutes = parse_duration_minutes(duration)
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn -> format_localized_duration(minutes) end)
  end

  @doc """
  Generates calendar links for various providers.
  """
  @spec calendar_links(%{
          required(:title) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:description) => String.t(),
          required(:location) => String.t()
        }) :: %{
          required(:google) => String.t(),
          required(:outlook) => String.t(),
          required(:yahoo) => String.t()
        }
  def calendar_links(%{
        title: title,
        start_time: start_time,
        end_time: end_time,
        description: description,
        location: location
      }) do
    # Format times for calendar URLs
    start_str = format_calendar_time(start_time)
    end_str = format_calendar_time(end_time)

    %{
      google: build_google_calendar_url(title, start_str, end_str, description, location),
      outlook: build_outlook_calendar_url(title, start_str, end_str, description, location),
      yahoo: build_yahoo_calendar_url(title, start_str, end_str, description, location)
    }
  end

  # Private functions

  defp format_calendar_time(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
    |> String.replace(~r/\.\d+/, "")
  end

  defp build_google_calendar_url(title, start_time, end_time, description, location) do
    params = %{
      action: "TEMPLATE",
      text: title,
      dates: "#{start_time}/#{end_time}",
      details: description,
      location: location
    }

    "https://calendar.google.com/calendar/render?#{URI.encode_query(params)}"
  end

  defp build_outlook_calendar_url(title, start_time, end_time, description, location) do
    params = %{
      subject: title,
      startdt: start_time,
      enddt: end_time,
      body: description,
      location: location
    }

    "https://outlook.live.com/calendar/0/deeplink/compose?#{URI.encode_query(params)}"
  end

  defp build_yahoo_calendar_url(title, start_time, end_time, description, _location) do
    params = %{
      v: "60",
      title: title,
      st: start_time,
      et: end_time,
      desc: description
    }

    "https://calendar.yahoo.com/?#{URI.encode_query(params)}"
  end

  @doc """
  Translates a location label based on location_type.
  Must be called within a `Gettext.with_locale` block to produce the correct locale.
  Falls back to the raw location string, or a translated default if nil.
  """
  @spec format_location(%{
          optional(:location_type) => atom() | nil,
          optional(:location) => String.t() | nil,
          optional(atom()) => term()
        }) :: String.t()
  def format_location(%{location_type: :video}), do: dgettext("emails", "Video Call")
  def format_location(%{location_type: :phone}), do: dgettext("emails", "Phone Call")
  def format_location(details), do: details[:location] || dgettext("emails", "TBD")

  @doc """
  Truncates text to a maximum length with ellipsis.
  """
  @spec truncate(String.t(), integer()) :: String.t()
  def truncate(text, max_length) when is_binary(text) and is_integer(max_length) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length - 3) <> "..."
    end
  end

  @doc """
  Returns the brand logo as a Base64 data URI.
  This ensures the logo is always displayed in email clients without needing
  to fetch it from a (potentially unreachable) development server.
  """
  @spec get_logo_data_uri() :: String.t()
  def get_logo_data_uri do
    case :ets.lookup(:tymeslot_email_assets, :logo_data_uri) do
      [{:logo_data_uri, data_uri}] ->
        data_uri

      [] ->
        path =
          Path.join([
            :code.priv_dir(:tymeslot),
            "static",
            "images",
            "brand",
            "logo-with-text.svg"
          ])

        data_uri =
          case File.read(path) do
            {:ok, content} ->
              encoded = Base.encode64(content)
              "data:image/svg+xml;base64,#{encoded}"

            _other ->
              ""
          end

        :ets.insert(:tymeslot_email_assets, {:logo_data_uri, data_uri})
        data_uri
    end
  end

  @doc """
  Sanitizes text for email display.
  """
  @spec sanitize_for_email(String.t() | nil) :: String.t()
  def sanitize_for_email(nil), do: ""

  def sanitize_for_email(text) when is_binary(text) do
    text
    |> String.trim()
    |> HTML.html_escape()
    |> HTML.safe_to_string()
  end

  defp parse_duration_minutes(minutes) when is_integer(minutes) and minutes > 0, do: minutes

  defp parse_duration_minutes(str) when is_binary(str) do
    case Regex.run(~r/^\s*(\d+)\s*(?:-?\s*min(?:utes?)?)?\s*$/i, str) do
      [_full, m] -> String.to_integer(m)
      _no_match -> 0
    end
  end

  defp parse_duration_minutes(_other), do: 0

  defp format_localized_duration(0), do: ""

  defp format_localized_duration(m) when m < 60 do
    "#{m} #{dngettext("emails", "minute", "minutes", m)}"
  end

  defp format_localized_duration(60), do: "1 #{dngettext("emails", "hour", "hours", 1)}"
  defp format_localized_duration(90), do: "1.5 #{dngettext("emails", "hour", "hours", 2)}"

  defp format_localized_duration(m) when rem(m, 60) == 0 do
    hours = div(m, 60)
    "#{hours} #{dngettext("emails", "hour", "hours", hours)}"
  end

  defp format_localized_duration(m) do
    h = div(m, 60)
    mins = rem(m, 60)

    "#{h} #{dngettext("emails", "hour", "hours", h)} #{mins} #{dngettext("emails", "minute", "minutes", mins)}"
  end

  @doc """
  Formats currency based on cents and currency code.
  Defaults to EUR (€) if currency is not provided or recognized.
  """
  @spec format_currency(integer(), String.t() | nil) :: String.t()
  def format_currency(cents, currency \\ "eur") do
    symbol =
      case String.downcase(currency || "eur") do
        "usd" -> "$"
        "gbp" -> "£"
        "jpy" -> "¥"
        _other -> "€"
      end

    amount = cents / 100
    "#{symbol}#{:erlang.float_to_binary(amount / 1, decimals: 2)}"
  end
end
