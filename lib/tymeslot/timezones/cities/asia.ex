defmodule Tymeslot.Timezones.Cities.Asia do
  @moduledoc "Timezone cities for Asia."

  @spec cities() :: [{String.t(), String.t(), String.t(), String.t()}]
  def cities do
    [
      # Middle East
      {"Asia/Dubai", "Dubai", "United Arab Emirates", "AE"},
      {"Asia/Riyadh", "Riyadh", "Saudi Arabia", "SA"},
      {"Asia/Qatar", "Doha", "Qatar", "QA"},
      {"Asia/Tehran", "Tehran", "Iran", "IR"},
      {"Asia/Baghdad", "Baghdad", "Iraq", "IQ"},
      {"Asia/Beirut", "Beirut", "Lebanon", "LB"},
      {"Asia/Jerusalem", "Jerusalem", "Israel", "IL"},
      {"Asia/Tbilisi", "Tbilisi", "Georgia", "GE"},
      {"Asia/Yerevan", "Yerevan", "Armenia", "AM"},
      {"Asia/Baku", "Baku", "Azerbaijan", "AZ"},
      # Central Asia
      {"Asia/Kabul", "Kabul", "Afghanistan", "AF"},
      {"Asia/Almaty", "Almaty", "Kazakhstan", "KZ"},
      {"Asia/Tashkent", "Tashkent", "Uzbekistan", "UZ"},
      {"Asia/Ashgabat", "Ashgabat", "Turkmenistan", "TM"},
      {"Asia/Dushanbe", "Dushanbe", "Tajikistan", "TJ"},
      {"Asia/Bishkek", "Bishkek", "Kyrgyzstan", "KG"},
      # Russia (Asian)
      {"Asia/Yekaterinburg", "Yekaterinburg", "Russia", "RU"},
      {"Asia/Novosibirsk", "Novosibirsk", "Russia", "RU"},
      {"Asia/Irkutsk", "Irkutsk", "Russia", "RU"},
      {"Asia/Vladivostok", "Vladivostok", "Russia", "RU"},
      # South Asia
      {"Asia/Karachi", "Karachi", "Pakistan", "PK"},
      {"Asia/Kolkata", "Kolkata", "India", "IN"},
      {"Asia/Colombo", "Colombo", "Sri Lanka", "LK"},
      {"Asia/Kathmandu", "Kathmandu", "Nepal", "NP"},
      {"Asia/Dhaka", "Dhaka", "Bangladesh", "BD"},
      # Southeast Asia
      {"Asia/Yangon", "Yangon", "Myanmar", "MM"},
      {"Asia/Bangkok", "Bangkok", "Thailand", "TH"},
      {"Asia/Vientiane", "Vientiane", "Laos", "LA"},
      {"Asia/Phnom_Penh", "Phnom Penh", "Cambodia", "KH"},
      {"Asia/Ho_Chi_Minh", "Ho Chi Minh City", "Vietnam", "VN"},
      {"Asia/Jakarta", "Jakarta", "Indonesia", "ID"},
      {"Asia/Makassar", "Makassar", "Indonesia", "ID"},
      {"Asia/Singapore", "Singapore", "Singapore", "SG"},
      {"Asia/Kuala_Lumpur", "Kuala Lumpur", "Malaysia", "MY"},
      {"Asia/Brunei", "Bandar Seri Begawan", "Brunei", "BN"},
      {"Asia/Manila", "Manila", "Philippines", "PH"},
      # East Asia
      {"Asia/Ulaanbaatar", "Ulaanbaatar", "Mongolia", "MN"},
      {"Asia/Shanghai", "Shanghai", "China", "CN"},
      {"Asia/Hong_Kong", "Hong Kong", "Hong Kong", "HK"},
      {"Asia/Taipei", "Taipei", "Taiwan", "TW"},
      {"Asia/Seoul", "Seoul", "South Korea", "KR"},
      {"Asia/Tokyo", "Tokyo", "Japan", "JP"},
      {"Asia/Macau", "Macau", "Macau", "MO"}
    ]
  end
end
