defmodule Tymeslot.Emails.Shared.SharedHelpers do
  @moduledoc """
  Shared helper functions for email templates.
  Centralizes common formatting and utility functions used across all email templates.
  """

  alias Phoenix.HTML
  alias TymeslotWeb.Endpoint

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
  Formats a date into a short readable format.
  Example: "Nov 25"
  """
  @spec format_date_short(Date.t() | DateTime.t() | NaiveDateTime.t()) :: String.t()
  def format_date_short(%Date{} = date) do
    Calendar.strftime(date, "%b %d")
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
  Formats a time with timezone.
  Example: "02:30 PM PST"
  """
  @spec format_time(DateTime.t()) :: String.t()
  def format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%I:%M %p %Z")
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
  Example: "30 minutes"
  """
  @spec format_duration(integer()) :: String.t()
  def format_duration(minutes) when is_integer(minutes) do
    "#{minutes} minutes"
  end

  @doc """
  Generates calendar links for various providers.
  """
  @spec calendar_links(map()) :: map()
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
end
