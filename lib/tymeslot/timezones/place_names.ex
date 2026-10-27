defmodule Tymeslot.Timezones.PlaceNames do
  @moduledoc """
  The picker's city and country names in each supported language but English.

  Read at compile time from `priv/cldr/place_names/<locale>.json`, which maps
  IANA ids to city names and ISO 3166 codes to country names (`priv/cldr/LICENSE`
  says where they come from). English needs no file: the city lists are written
  in it. A locale without a file, or a place its file does not name, yields
  `nil`, and the caller keeps the English name.
  """

  @dir Path.join([__DIR__, "../../../priv/cldr/place_names"])

  @locales :tymeslot
           |> Application.compile_env(:locales, [])
           |> Keyword.get(:supported, [])
           |> Enum.map(& &1.code)
           |> List.delete("en")

  @paths for locale <- @locales,
             path = Path.join(@dir, "#{locale}.json"),
             File.exists?(path),
             do: {locale, path}

  for {_locale, path} <- @paths, do: @external_resource(path)

  @names Map.new(@paths, fn {locale, path} ->
           {locale, path |> File.read!() |> Jason.decode!()}
         end)

  @doc "The locales that have names of their own, English excluded."
  @spec locales() :: [String.t()]
  def locales, do: Map.keys(@names)

  @spec city(String.t(), String.t()) :: String.t() | nil
  def city(locale, timezone_id), do: get_in(@names, [locale, "cities", timezone_id])

  @spec country(String.t(), String.t()) :: String.t() | nil
  def country(locale, country_code), do: get_in(@names, [locale, "countries", country_code])
end
