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

  describe "when booking analytics is disabled" do
    setup do
      Application.put_env(:tymeslot, :booking_analytics_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :booking_analytics_enabled, true) end)
    end

    test "enabled?/0 returns false" do
      refute Analytics.enabled?()
    end

    test "log_page_view/1 short-circuits and persists nothing", %{user: user} do
      assert {:ok, :disabled} =
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

      assert Repo.aggregate(EventSchema, :count, :id) == 0
    end

    test "log_page_view/1 emits a :disabled telemetry outcome", %{user: user} do
      test_pid = self()
      handler_id = "test-analytics-wiring-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:tymeslot, :analytics, :page_view],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:analytics_outcome, metadata.outcome})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Analytics.log_page_view(%{
        path: "/alice/intro",
        user_id: user.id,
        meeting_type_id: nil,
        ip: "1.2.3.4",
        user_agent: "Mozilla/5.0 ... Chrome/126",
        session_id: "sess-1",
        params: %{},
        referrer: nil
      })

      assert_receive {:analytics_outcome, :disabled}
    end
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

    test "drops an organizer's visit to their own booking page", %{user: user} do
      assert {:ok, :filtered_owner} =
               Analytics.log_page_view(%{
                 path: "/alice/intro",
                 user_id: user.id,
                 meeting_type_id: nil,
                 ip: "1.2.3.4",
                 user_agent: "Mozilla/5.0 ... Chrome/126",
                 session_id: "sess-owner",
                 params: %{},
                 referrer: nil,
                 viewer_user_id: user.id
               })

      assert Repo.aggregate(EventSchema, :count, :id) == 0
    end

    test "records a signed-in visitor viewing a different organizer's page", %{user: user} do
      other = Factory.insert(:user)

      assert {:ok, %EventSchema{}} =
               Analytics.log_page_view(%{
                 path: "/alice/intro",
                 user_id: user.id,
                 meeting_type_id: nil,
                 ip: "1.2.3.4",
                 user_agent: "Mozilla/5.0 ... Chrome/126",
                 session_id: "sess-other",
                 params: %{},
                 referrer: nil,
                 viewer_user_id: other.id
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

    @tag :capture_log
    test "drops events when rate limit exceeded", %{user: user} do
      # Same visitor_hash will be computed for identical (ip, ua)
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
    @tag :capture_log
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
      assert event.device_type == "desktop"
    end
  end

  # TR2 — conversion_rate/2 unit tests
  describe "conversion_rate/2" do
    test "returns 0.0 when unique_visitors is zero" do
      assert Analytics.conversion_rate(0, 0) == "0.0"
      assert Analytics.conversion_rate(5, 0) == "0.0"
    end

    test "caps at 100.0 when converting visitors exceed unique visitors" do
      # 5 converting, 4 unique → would be 125% (a dropped page-view write) but
      # capped at 100
      assert Analytics.conversion_rate(5, 4) == "100.0"
    end

    test "returns the correct percentage for normal cases" do
      # 2 converting visitors out of 3 unique visitors → 66.7%
      assert Analytics.conversion_rate(2, 3) == "66.7"
    end

    test "returns 100.0 when converting visitors equal unique visitors" do
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
      assert linkedin = Enum.find(rows, &(&1.utm_source == "linkedin"))

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
      assert newsletter = Enum.find(rows, &(&1.utm_source == "newsletter"))

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
      assert twitter = Enum.find(rows, &(&1.utm_source == "twitter"))

      assert twitter.visits == 1
      assert twitter.unique_visitors == 1
      assert twitter.bookings == 1
      # No visitor_hash on the meeting → not a converting visitor
      assert twitter.converting_visitors == 0
    end

    test "counts distinct converting visitors per source from visitor_hash",
         %{user: user, from: from, to: to, now: now} do
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      # One visitor (same hash) books twice from the same source → one
      # converting visitor across two bookings. Distinct start times avoid the
      # unique_confirmed_meeting_per_organizer_at_time constraint.
      for i <- 1..2 do
        Factory.insert(:meeting,
          organizer_user_id: user.id,
          start_time: DateTime.add(base, i * 60, :minute),
          end_time: DateTime.add(base, i * 60 + 30, :minute),
          utm_source: "podcast",
          visitor_hash: "converting-visitor-1"
        )
      end

      rows = Analytics.attribution_table(user.id, from, to)
      podcast = Enum.find(rows, &(&1.utm_source == "podcast"))

      assert podcast.bookings == 2
      assert podcast.converting_visitors == 1
    end
  end

  # TR3 — count_converting_visitors/3 (distinct bookers carrying a visitor_hash)
  describe "count_converting_visitors/3" do
    setup do
      now = DateTime.utc_now()
      from = DateTime.add(now, -3600, :second)
      to = DateTime.add(now, 3600, :second)
      %{from: from, to: to, now: now}
    end

    test "counts distinct visitor_hash, deduping repeats and ignoring nils",
         %{user: user, from: from, to: to, now: now} do
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      # Distinct start times avoid the per-organizer-per-time unique constraint.
      insert_booking = fn hash, offset ->
        Factory.insert(:meeting,
          organizer_user_id: user.id,
          start_time: DateTime.add(base, offset * 60, :minute),
          end_time: DateTime.add(base, offset * 60 + 30, :minute),
          visitor_hash: hash
        )
      end

      insert_booking.("visitor-a", 1)
      insert_booking.("visitor-a", 2)
      insert_booking.("visitor-b", 3)
      # Admin/import/API booking with no tracked view → excluded
      insert_booking.(nil, 4)

      assert Analytics.count_converting_visitors(user.id, from, to) == 2
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
