defmodule Tymeslot.Emails.Shared.UrlsTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Urls

  # config/test.exs serves the endpoint on TEST_PORT, defaulting to 4002. The
  # expected URLs are pinned rather than rebuilt from `Endpoint.url/0`, which
  # is the call under test and so can never disagree with itself.
  @app_url "http://localhost:#{System.get_env("TEST_PORT") || "4002"}"

  describe "get_app_url/0" do
    test "returns a valid URL string" do
      url = Urls.get_app_url()

      assert url =~ ~r/^https?:\/\//
    end

    test "returns the configured scheme, host and port, with no trailing slash" do
      assert Urls.get_app_url() == @app_url
    end
  end

  describe "build_url/1" do
    test "builds URL with root path" do
      assert Urls.build_url("/") == "#{@app_url}/"
    end

    test "builds URL with specific path" do
      assert Urls.build_url("/meetings/123") == "#{@app_url}/meetings/123"
    end

    test "adds the missing leading slash rather than gluing the path to the host" do
      # Without normalisation this yields "http://localhost:4002meetings/123",
      # which is a broken link no assertion on the suffix alone would catch.
      assert Urls.build_url("meetings/123") == "#{@app_url}/meetings/123"
    end

    test "does not double the slash on a path that already has one" do
      refute Urls.build_url("/meetings/123") =~ "//meetings"
    end
  end

  describe "calendar_links/1" do
    setup do
      meeting_details = %{
        title: "Team Meeting",
        start_time: ~U[2024-11-25 14:30:00Z],
        end_time: ~U[2024-11-25 15:30:00Z],
        description: "Discuss project updates",
        location: "Conference Room A"
      }

      %{meeting_details: meeting_details}
    end

    test "generates all calendar provider links", %{meeting_details: details} do
      links = Urls.calendar_links(details)

      assert Map.has_key?(links, :google)
      assert Map.has_key?(links, :outlook)
      assert Map.has_key?(links, :yahoo)
    end

    test "generates valid Google Calendar URL", %{meeting_details: details} do
      links = Urls.calendar_links(details)

      assert links.google =~ "https://calendar.google.com/calendar/render"
      assert links.google =~ "action=TEMPLATE"
      assert links.google =~ URI.encode_www_form(details.title)
      assert links.google =~ URI.encode_www_form(details.description)
      assert links.google =~ URI.encode_www_form(details.location)
    end

    test "generates valid Outlook Calendar URL", %{meeting_details: details} do
      links = Urls.calendar_links(details)

      assert links.outlook =~ "https://outlook.live.com/calendar/0/deeplink/compose"
      assert links.outlook =~ "subject="
      assert links.outlook =~ "startdt="
      assert links.outlook =~ "enddt="
    end

    test "generates valid Yahoo Calendar URL", %{meeting_details: details} do
      links = Urls.calendar_links(details)

      assert links.yahoo =~ "https://calendar.yahoo.com"
      assert links.yahoo =~ "v=60"
      assert links.yahoo =~ "title="
      assert links.yahoo =~ "st="
      assert links.yahoo =~ "et="
    end

    test "includes meeting details in URLs", %{meeting_details: details} do
      links = Urls.calendar_links(details)

      for url <- [links.google, links.outlook, links.yahoo] do
        assert url =~ URI.encode_www_form(details.title)
        assert url =~ URI.encode_www_form(details.description)
      end
    end

    test "formats datetime correctly in URLs", %{meeting_details: details} do
      links = Urls.calendar_links(details)

      # Calendar URLs use the format YYYYMMDDTHHmmssZ — no hyphens or colons, Z suffix
      # The slash separator between start and end is URL-encoded as %2F
      assert links.google =~ ~r/dates=\d{8}T\d{6}Z(%2F|\/)\d{8}T\d{6}Z/
    end

    test "shifts non-UTC datetime to UTC and appends Z in Google Calendar URL" do
      # 14:30 America/New_York is 19:30 UTC
      start_time = DateTime.new!(~D[2024-11-25], ~T[14:30:00], "America/New_York")
      end_time = DateTime.new!(~D[2024-11-25], ~T[15:30:00], "America/New_York")

      links =
        Urls.calendar_links(%{
          title: "Test",
          start_time: start_time,
          end_time: end_time,
          description: "desc",
          location: "loc"
        })

      assert links.google =~ "20241125T193000Z"
      assert links.google =~ "20241125T203000Z"
    end
  end
end
