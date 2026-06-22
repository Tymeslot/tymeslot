defmodule Tymeslot.Analytics.BotDetector do
  @moduledoc """
  User-agent based classification: bot detection, browser family, and
  device type.

  Bot detection is a deliberately simple denylist that catches declared
  crawlers (Googlebot, Bingbot, scrapers, scripts). Headless browsers that
  impersonate Chrome are not caught — they are rare against booking
  pages and would require a WAF to filter reliably.

  Combined with `connected?(socket)` gating in the mount hook, this
  produces dashboards within ~5% of true human traffic.

  Browser family and device type are coarse, dependency-free heuristics
  over the user-agent string. They are good enough for understanding the
  shape of booking-page traffic (e.g. "most visitors are on mobile")
  without the cost and footprint of a full UA-parsing library.
  """

  @bot_patterns [
    ~r/bot/i,
    ~r/crawler/i,
    ~r/spider/i,
    ~r/slurp/i,
    ~r/curl/i,
    ~r/wget/i,
    ~r/python-requests/i,
    ~r/python-urllib/i,
    ~r/go-http-client/i,
    ~r/java\//i,
    ~r/httpclient/i,
    ~r/headlesschrome/i,
    ~r/phantomjs/i,
    ~r/facebookexternalhit/i,
    ~r/twitterbot/i,
    ~r/linkedinbot/i,
    ~r/whatsapp/i,
    ~r/telegrambot/i,
    ~r/discordbot/i
  ]

  @spec bot?(String.t() | nil) :: boolean()
  def bot?(nil), do: true
  def bot?(""), do: true

  def bot?(user_agent) when is_binary(user_agent) do
    Enum.any?(@bot_patterns, &Regex.match?(&1, user_agent))
  end

  @spec ua_family(String.t() | nil) :: String.t()
  def ua_family(nil), do: "unknown"
  def ua_family(""), do: "unknown"

  def ua_family(ua) when is_binary(ua) do
    cond do
      bot?(ua) -> "bot"
      ua =~ ~r/Edg\//i -> "edge"
      ua =~ ~r/Chrome\//i -> "chrome"
      ua =~ ~r/Firefox\//i -> "firefox"
      ua =~ ~r/Safari\//i -> "safari"
      true -> "other"
    end
  end

  @doc """
  Classifies the device into `"mobile"`, `"tablet"`, `"desktop"`, or
  `"unknown"` from the user-agent string.

  Tablets are checked before phones because tablet user agents (notably
  the iPad) also carry the `Mobile` token, so a naive phone-first check
  would misclassify every tablet as a phone.
  """
  @spec device_type(String.t() | nil) :: String.t()
  def device_type(nil), do: "unknown"
  def device_type(""), do: "unknown"

  def device_type(ua) when is_binary(ua) do
    cond do
      ua =~ ~r/iPad|Tablet|Nexus 7|Kindle|Silk|PlayBook/i -> "tablet"
      ua =~ ~r/Mobi|Android.+Mobile|iPhone|iPod|Windows Phone|IEMobile/i -> "mobile"
      true -> "desktop"
    end
  end
end
