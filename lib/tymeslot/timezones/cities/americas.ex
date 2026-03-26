defmodule Tymeslot.Timezones.Cities.Americas do
  @moduledoc "Timezone cities for the Americas."

  @spec cities() :: [{String.t(), String.t(), String.t(), String.t()}]
  def cities do
    [
      # North America — US
      {"Pacific/Honolulu", "Honolulu", "United States", "US"},
      {"America/Adak", "Adak", "United States", "US"},
      {"America/Anchorage", "Anchorage", "United States", "US"},
      {"America/Los_Angeles", "Los Angeles", "United States", "US"},
      {"America/Denver", "Denver", "United States", "US"},
      {"America/Phoenix", "Phoenix", "United States", "US"},
      {"America/Chicago", "Chicago", "United States", "US"},
      {"America/New_York", "New York", "United States", "US"},
      {"America/Indiana/Indianapolis", "Indianapolis", "United States", "US"},
      {"America/Kentucky/Louisville", "Louisville", "United States", "US"},
      # North America — Canada
      {"America/Vancouver", "Vancouver", "Canada", "CA"},
      {"America/Edmonton", "Edmonton", "Canada", "CA"},
      {"America/Calgary", "Calgary", "Canada", "CA"},
      {"America/Winnipeg", "Winnipeg", "Canada", "CA"},
      {"America/Toronto", "Toronto", "Canada", "CA"},
      {"America/Montreal", "Montreal", "Canada", "CA"},
      {"America/Halifax", "Halifax", "Canada", "CA"},
      {"America/St_Johns", "St. John's", "Canada", "CA"},
      # Mexico
      {"America/Mexico_City", "Mexico City", "Mexico", "MX"},
      {"America/Tijuana", "Tijuana", "Mexico", "MX"},
      {"America/Monterrey", "Monterrey", "Mexico", "MX"},
      # Central America & Caribbean
      {"America/Guatemala", "Guatemala City", "Guatemala", "GT"},
      {"America/Costa_Rica", "San Jose", "Costa Rica", "CR"},
      {"America/Panama", "Panama City", "Panama", "PA"},
      {"America/Havana", "Havana", "Cuba", "CU"},
      {"America/Jamaica", "Kingston", "Jamaica", "JM"},
      {"America/Port_of_Spain", "Port of Spain", "Trinidad and Tobago", "TT"},
      {"America/Puerto_Rico", "San Juan", "Puerto Rico", "PR"},
      # South America
      {"America/Bogota", "Bogota", "Colombia", "CO"},
      {"America/Lima", "Lima", "Peru", "PE"},
      {"America/Caracas", "Caracas", "Venezuela", "VE"},
      {"America/La_Paz", "La Paz", "Bolivia", "BO"},
      {"America/Guyana", "Georgetown", "Guyana", "GY"},
      {"America/Santiago", "Santiago", "Chile", "CL"},
      {"America/Asuncion", "Asuncion", "Paraguay", "PY"},
      {"America/Montevideo", "Montevideo", "Uruguay", "UY"},
      {"America/Sao_Paulo", "Sao Paulo", "Brazil", "BR"},
      {"America/Manaus", "Manaus", "Brazil", "BR"},
      {"America/Argentina/Buenos_Aires", "Buenos Aires", "Argentina", "AR"}
    ]
  end
end
