defmodule Tymeslot.Analytics.BotDetectorTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Tymeslot.Analytics.BotDetector

  describe "bot?/1" do
    test "flags common crawler user agents" do
      assert BotDetector.bot?(
               "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
             )

      assert BotDetector.bot?("Mozilla/5.0 (compatible; bingbot/2.0)")
      assert BotDetector.bot?("Mozilla/5.0 (compatible; AhrefsBot/7.0)")
      assert BotDetector.bot?("Mozilla/5.0 (compatible; SemrushBot/7~bl)")
    end

    test "flags generic crawler indicators" do
      assert BotDetector.bot?("Some-Spider/1.0")
      assert BotDetector.bot?("Some-Crawler/1.0")
      assert BotDetector.bot?("curl/8.0")
      assert BotDetector.bot?("python-requests/2.31.0")
    end

    test "does not flag real browser user agents" do
      refute BotDetector.bot?(
               "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
             )

      refute BotDetector.bot?(
               "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
             )
    end

    test "treats nil and empty as a bot (no UA == automated)" do
      assert BotDetector.bot?(nil)
      assert BotDetector.bot?("")
    end
  end

  describe "ua_family/1" do
    test "returns a coarse bucket label" do
      assert BotDetector.ua_family("Mozilla/5.0 ... Chrome/126") == "chrome"
      assert BotDetector.ua_family("Mozilla/5.0 ... Safari/17") == "safari"
      assert BotDetector.ua_family("Mozilla/5.0 ... Firefox/127") == "firefox"
      assert BotDetector.ua_family("Mozilla/5.0 ... Edg/126") == "edge"
      assert BotDetector.ua_family("Googlebot/2.1") == "bot"
      assert BotDetector.ua_family(nil) == "unknown"
    end
  end
end
