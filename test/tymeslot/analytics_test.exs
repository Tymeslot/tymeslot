defmodule Tymeslot.AnalyticsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :analytics
  @moduletag :database

  alias Tymeslot.Analytics
  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Factory
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Analytics, as: AnalyticsLimiter

  setup do
    user = Factory.insert(:user)
    RateLimiter.clear_all()
    %{user: user}
  end

  describe "log_page_view/1" do
    test "writes an event when inputs are valid", %{user: user} do
      assert {:ok, %EventSchema{}} =
               Analytics.log_page_view(%{
                 path: "/alice/intro",
                 user_id: user.id,
                 meeting_type_id: nil,
                 ip: "1.2.3.4",
                 user_agent: "Mozilla/5.0 ... Chrome/126",
                 session_id: "sess-1",
                 params: %{"utm_source" => "linkedin"},
                 referrer: "https://linkedin.com/feed"
               })

      assert Repo.aggregate(EventSchema, :count, :id) == 1
    end

    test "drops events from declared bots", %{user: user} do
      assert {:ok, :filtered_bot} =
               Analytics.log_page_view(%{
                 path: "/alice/intro",
                 user_id: user.id,
                 meeting_type_id: nil,
                 ip: "1.2.3.4",
                 user_agent: "Googlebot/2.1",
                 session_id: "sess-1",
                 params: %{},
                 referrer: nil
               })

      assert Repo.aggregate(EventSchema, :count, :id) == 0
    end

    test "drops events when rate limit exceeded", %{user: user} do
      # Same visitor_hash will be computed for identical (ip, ua, mt_id)
      attrs = %{
        path: "/alice/intro",
        user_id: user.id,
        meeting_type_id: nil,
        ip: "1.2.3.4",
        user_agent: "Mozilla/5.0 ... Chrome/126",
        session_id: "sess-1",
        params: %{},
        referrer: nil
      }

      for _i <- 1..30, do: assert({:ok, %EventSchema{}} = Analytics.log_page_view(attrs))
      assert {:ok, :filtered_rate_limit} = Analytics.log_page_view(attrs)

      assert Repo.aggregate(EventSchema, :count, :id) == 30
    end

    # TR5 — per-IP rate gate (300/min) fires independently of the visitor bucket.
    # We exhaust the IP bucket via the limiter directly (avoids a 300-iteration
    # log_page_view loop), then verify a single real call returns :filtered_rate_limit.
    test "drops events when the per-IP rate gate is exceeded", %{user: user} do
      ip = "5.6.7.8"
      bucket_key = "analytics:ip:" <> ip
      window_ms = 60_000
      limit = 300

      # Exhaust the IP bucket without going through log_page_view
      for _i <- 1..limit do
        AnalyticsLimiter.check_ip(bucket_key, window_ms, limit)
      end

      assert {:ok, :filtered_rate_limit} =
               Analytics.log_page_view(%{
                 path: "/alice/intro",
                 user_id: user.id,
                 meeting_type_id: nil,
                 ip: ip,
                 user_agent: "Mozilla/5.0 ... Chrome/126",
                 session_id: "sess-ip",
                 params: %{},
                 referrer: nil
               })
    end

    test "stores UTM, tracking_params, and referrer_host correctly", %{user: user} do
      {:ok, event} =
        Analytics.log_page_view(%{
          path: "/alice/intro",
          user_id: user.id,
          meeting_type_id: nil,
          ip: "1.2.3.4",
          user_agent: "Mozilla/5.0 ... Chrome/126",
          session_id: "sess-1",
          params: %{"utm_source" => "linkedin", "ref" => "newsletter"},
          referrer: "https://www.linkedin.com/feed/"
        })

      assert event.utm_source == "linkedin"
      assert event.tracking_params == %{"ref" => "newsletter"}
      assert event.referrer_host == "www.linkedin.com"
      assert event.user_agent_family == "chrome"
    end
  end

  # TR2 — conversion_rate/2 unit tests
  describe "conversion_rate/2" do
    test "returns 0.0 when unique_visitors is zero" do
      assert Analytics.conversion_rate(0, 0) == "0.0"
      assert Analytics.conversion_rate(5, 0) == "0.0"
    end

    test "caps at 100.0 when bookings exceed unique visitors" do
      # 5 bookings, 4 unique visitors → would be 125% but capped at 100
      assert Analytics.conversion_rate(5, 4) == "100.0"
    end

    test "returns the correct percentage for normal cases" do
      # 2 bookings out of 3 unique visitors → 66.7%
      assert Analytics.conversion_rate(2, 3) == "66.7"
    end

    test "returns 100.0 when bookings equal unique visitors" do
      assert Analytics.conversion_rate(10, 10) == "100.0"
    end
  end

  # TR3 — attribution_table/3 union behaviour
  describe "attribution_table/3" do
    setup do
      now = DateTime.utc_now()
      from = DateTime.add(now, -3600, :second)
      to = DateTime.add(now, 3600, :second)
      %{from: from, to: to, now: now}
    end

    test "source with visits but zero bookings appears with bookings: 0",
         %{user: user, from: from, to: to} do
      # Insert a page view so linkedin appears in the visits dataset
      {:ok, _event} =
        Analytics.log_page_view(%{
          path: "/alice/intro",
          user_id: user.id,
          meeting_type_id: nil,
          ip: "10.0.0.1",
          user_agent: "Mozilla/5.0 ... Firefox/120",
          session_id: "s1",
          params: %{"utm_source" => "linkedin"},
          referrer: nil
        })

      rows = Analytics.attribution_table(user.id, from, to)
      linkedin = Enum.find(rows, &(&1.utm_source == "linkedin"))

      assert linkedin != nil
      assert linkedin.visits == 1
      assert linkedin.bookings == 0
    end

    test "source with bookings but zero visits appears with visits: 0 and unique_visitors: 0",
         %{user: user, from: from, to: to, now: now} do
      # Insert a meeting with utm_source but no page view events
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      Factory.insert(:meeting,
        organizer_user_id: user.id,
        start_time: base,
        end_time: DateTime.add(base, 60, :minute),
        utm_source: "newsletter"
      )

      rows = Analytics.attribution_table(user.id, from, to)
      newsletter = Enum.find(rows, &(&1.utm_source == "newsletter"))

      assert newsletter != nil
      assert newsletter.visits == 0
      assert newsletter.unique_visitors == 0
      assert newsletter.bookings == 1
    end

    test "source present in both datasets merges counts correctly",
         %{user: user, from: from, to: to, now: now} do
      {:ok, _event} =
        Analytics.log_page_view(%{
          path: "/alice/intro",
          user_id: user.id,
          meeting_type_id: nil,
          ip: "10.0.0.2",
          user_agent: "Mozilla/5.0 ... Chrome/126",
          session_id: "s2",
          params: %{"utm_source" => "twitter"},
          referrer: nil
        })

      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      Factory.insert(:meeting,
        organizer_user_id: user.id,
        start_time: base,
        end_time: DateTime.add(base, 60, :minute),
        utm_source: "twitter"
      )

      rows = Analytics.attribution_table(user.id, from, to)
      twitter = Enum.find(rows, &(&1.utm_source == "twitter"))

      assert twitter != nil
      assert twitter.visits == 1
      assert twitter.unique_visitors == 1
      assert twitter.bookings == 1
    end
  end

  # TR3 — extract_attribution/2 includes referrer_host
  describe "extract_attribution/2" do
    test "merges referrer_host alongside utm fields" do
      params = %{"utm_source" => "google", "utm_medium" => "cpc"}
      referrer = "https://www.google.com/search"

      result = Analytics.extract_attribution(params, referrer)

      assert result.utm_source == "google"
      assert result.utm_medium == "cpc"
      assert result.referrer_host == "www.google.com"
      assert Map.has_key?(result, :tracking_params)
    end

    test "referrer_host is nil when referrer is nil" do
      result = Analytics.extract_attribution(%{}, nil)
      assert result.referrer_host == nil
    end
  end
end
