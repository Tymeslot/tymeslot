defmodule Tymeslot.Integrations.Calendar.EventTimeFormatter do
  @moduledoc """
  Normalizes event date/time payloads for calendar providers.
  """

  @default_timezone "UTC"

  @doc """
  Formats a datetime or ISO8601 string into the provider payload structure.

  ## Options
    * `:include_when_missing?` - include a timeZone field even when none provided (default: false)
    * `:include_timezone_on_error?` - include the timeZone key when parsing/conversion fails (default: false)
    * `:default_timezone` - fallback timezone label (default: "UTC")
  """
  @spec format_with_timezone(DateTime.t() | String.t() | nil, String.t() | nil, keyword()) ::
          map() | nil
  def format_with_timezone(value, timezone, opts \\ [])

  def format_with_timezone(nil, _timezone, _opts), do: nil

  def format_with_timezone(%DateTime{} = datetime, timezone, opts) do
    if is_binary(timezone) do
      case DateTime.shift_zone(datetime, timezone) do
        {:ok, shifted} ->
          %{
            "dateTime" => remove_trailing_z(DateTime.to_iso8601(shifted)),
            "timeZone" => timezone
          }

        {:error, _} ->
          fallback_map(DateTime.to_iso8601(datetime), timezone, opts, :error)
      end
    else
      fallback_map(DateTime.to_iso8601(datetime), timezone, opts, :missing)
    end
  end

  def format_with_timezone(datetime_string, timezone, opts) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, datetime, _offset} ->
        format_with_timezone(datetime, timezone, opts)

      {:error, _} ->
        fallback_map(datetime_string, timezone, opts, :error)
    end
  end

  def format_with_timezone(_, _timezone, _opts), do: nil

  defp fallback_map(iso_string, timezone, opts, context) do
    include_when_missing? = Keyword.get(opts, :include_when_missing?, false)
    include_on_error? = Keyword.get(opts, :include_timezone_on_error?, false)

    cond do
      context == :error and include_on_error? ->
        %{"dateTime" => iso_string, "timeZone" => timezone || default_timezone(opts)}

      context == :missing and include_when_missing? ->
        %{"dateTime" => iso_string, "timeZone" => timezone || default_timezone(opts)}

      true ->
        %{"dateTime" => iso_string}
    end
  end

  defp remove_trailing_z(iso_string) do
    if String.ends_with?(iso_string, "Z") do
      String.slice(iso_string, 0, byte_size(iso_string) - 1)
    else
      iso_string
    end
  end

  defp default_timezone(opts), do: Keyword.get(opts, :default_timezone, @default_timezone)
end
