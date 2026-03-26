defmodule Tymeslot.Timezones.Cities.Europe do
  @moduledoc "Timezone cities for Europe."

  @spec cities() :: [{String.t(), String.t(), String.t(), String.t()}]
  def cities do
    [
      # Western Europe
      {"Europe/London", "London", "United Kingdom", "GB"},
      {"Europe/Dublin", "Dublin", "Ireland", "IE"},
      {"Europe/Lisbon", "Lisbon", "Portugal", "PT"},
      {"Europe/Madrid", "Madrid", "Spain", "ES"},
      {"Europe/Paris", "Paris", "France", "FR"},
      {"Europe/Amsterdam", "Amsterdam", "Netherlands", "NL"},
      {"Europe/Brussels", "Brussels", "Belgium", "BE"},
      {"Europe/Luxembourg", "Luxembourg", "Luxembourg", "LU"},
      # Central Europe
      {"Europe/Berlin", "Berlin", "Germany", "DE"},
      {"Europe/Zurich", "Zurich", "Switzerland", "CH"},
      {"Europe/Vienna", "Vienna", "Austria", "AT"},
      {"Europe/Rome", "Rome", "Italy", "IT"},
      {"Europe/Malta", "Valletta", "Malta", "MT"},
      {"Europe/Prague", "Prague", "Czech Republic", "CZ"},
      {"Europe/Warsaw", "Warsaw", "Poland", "PL"},
      {"Europe/Budapest", "Budapest", "Hungary", "HU"},
      {"Europe/Belgrade", "Belgrade", "Serbia", "RS"},
      {"Europe/Sarajevo", "Sarajevo", "Bosnia and Herzegovina", "BA"},
      {"Europe/Skopje", "Skopje", "North Macedonia", "MK"},
      {"Europe/Podgorica", "Podgorica", "Montenegro", "ME"},
      {"Europe/Tirane", "Tirana", "Albania", "AL"},
      {"Europe/Ljubljana", "Ljubljana", "Slovenia", "SI"},
      {"Europe/Bratislava", "Bratislava", "Slovakia", "SK"},
      {"Europe/Zagreb", "Zagreb", "Croatia", "HR"},
      # Northern Europe
      {"Europe/Stockholm", "Stockholm", "Sweden", "SE"},
      {"Europe/Oslo", "Oslo", "Norway", "NO"},
      {"Europe/Copenhagen", "Copenhagen", "Denmark", "DK"},
      {"Europe/Helsinki", "Helsinki", "Finland", "FI"},
      {"Atlantic/Reykjavik", "Reykjavik", "Iceland", "IS"},
      {"Europe/Tallinn", "Tallinn", "Estonia", "EE"},
      {"Europe/Riga", "Riga", "Latvia", "LV"},
      {"Europe/Vilnius", "Vilnius", "Lithuania", "LT"},
      # Eastern Europe & Caucasus
      {"Asia/Nicosia", "Nicosia", "Cyprus", "CY"},
      {"Europe/Kyiv", "Kyiv", "Ukraine", "UA"},
      {"Europe/Bucharest", "Bucharest", "Romania", "RO"},
      {"Europe/Sofia", "Sofia", "Bulgaria", "BG"},
      {"Europe/Athens", "Athens", "Greece", "GR"},
      {"Europe/Istanbul", "Istanbul", "Turkey", "TR"},
      {"Europe/Kaliningrad", "Kaliningrad", "Russia", "RU"},
      {"Europe/Moscow", "Moscow", "Russia", "RU"},
      {"Europe/Minsk", "Minsk", "Belarus", "BY"},
      {"Europe/Chisinau", "Chisinau", "Moldova", "MD"},
      {"Europe/Simferopol", "Simferopol", "Ukraine", "UA"}
    ]
  end
end
