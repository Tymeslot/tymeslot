defmodule Tymeslot.Timezones.Cities.Oceania do
  @moduledoc "Timezone cities for Oceania and the Pacific."

  @spec cities() :: [{String.t(), String.t(), String.t(), String.t()}]
  def cities do
    [
      # Australia
      {"Australia/Perth", "Perth", "Australia", "AU"},
      {"Australia/Adelaide", "Adelaide", "Australia", "AU"},
      {"Australia/Brisbane", "Brisbane", "Australia", "AU"},
      {"Australia/Sydney", "Sydney", "Australia", "AU"},
      {"Australia/Melbourne", "Melbourne", "Australia", "AU"},
      {"Australia/Hobart", "Hobart", "Australia", "AU"},
      {"Australia/Darwin", "Darwin", "Australia", "AU"},
      # New Zealand
      {"Pacific/Auckland", "Auckland", "New Zealand", "NZ"},
      # Pacific Islands
      {"Pacific/Port_Moresby", "Port Moresby", "Papua New Guinea", "PG"},
      {"Pacific/Noumea", "Noumea", "New Caledonia", "NC"},
      {"Pacific/Fiji", "Suva", "Fiji", "FJ"},
      {"Pacific/Apia", "Apia", "Samoa", "WS"},
      {"Pacific/Tongatapu", "Nuku'alofa", "Tonga", "TO"},
      {"Pacific/Guam", "Guam", "Guam", "GU"},
      {"Pacific/Pago_Pago", "Pago Pago", "American Samoa", "AS"},
      {"Pacific/Tahiti", "Papeete", "French Polynesia", "PF"},
      # Atlantic
      {"Atlantic/Azores", "Azores", "Portugal", "PT"}
    ]
  end
end
