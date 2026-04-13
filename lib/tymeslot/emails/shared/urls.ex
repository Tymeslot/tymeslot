defmodule Tymeslot.Emails.Shared.Urls do
  @moduledoc """
  App URL and calendar-link building helpers for Tymeslot emails.
  """

  alias TymeslotWeb.Endpoint

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
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
    |> String.replace(~r/\.\d+/, "")
    |> Kernel.<>("Z")
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
end
