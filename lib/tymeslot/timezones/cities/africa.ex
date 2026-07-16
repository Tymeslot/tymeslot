defmodule Tymeslot.Timezones.Cities.Africa do
  @moduledoc "Timezone cities for Africa."

  @spec cities() :: [{String.t(), String.t(), String.t(), String.t()}]
  def cities do
    [
      # North Africa
      {"Africa/Cairo", "Cairo", "Egypt", "EG"},
      {"Africa/Casablanca", "Casablanca", "Morocco", "MA"},
      {"Africa/Algiers", "Algiers", "Algeria", "DZ"},
      {"Africa/Tunis", "Tunis", "Tunisia", "TN"},
      {"Africa/Tripoli", "Tripoli", "Libya", "LY"},
      # East Africa
      {"Africa/Nairobi", "Nairobi", "Kenya", "KE"},
      {"Africa/Addis_Ababa", "Addis Ababa", "Ethiopia", "ET"},
      {"Africa/Dar_es_Salaam", "Dar es Salaam", "Tanzania", "TZ"},
      {"Africa/Kampala", "Kampala", "Uganda", "UG"},
      {"Africa/Khartoum", "Khartoum", "Sudan", "SD"},
      {"Africa/Juba", "Juba", "South Sudan", "SS"},
      # Indian Ocean
      {"Indian/Mauritius", "Port Louis", "Mauritius", "MU"},
      # West Africa
      {"Africa/Lagos", "Lagos", "Nigeria", "NG"},
      {"Africa/Accra", "Accra", "Ghana", "GH"},
      {"Africa/Abidjan", "Abidjan", "Ivory Coast", "CI"},
      {"Africa/Dakar", "Dakar", "Senegal", "SN"},
      # Southern Africa
      {"Africa/Johannesburg", "Johannesburg", "South Africa", "ZA"},
      {"Africa/Harare", "Harare", "Zimbabwe", "ZW"},
      {"Africa/Windhoek", "Windhoek", "Namibia", "NA"},
      {"Africa/Maputo", "Maputo", "Mozambique", "MZ"},
      # Central Africa
      {"Africa/Kinshasa", "Kinshasa", "DR Congo", "CD"},
      {"Africa/Luanda", "Luanda", "Angola", "AO"}
    ]
  end
end
