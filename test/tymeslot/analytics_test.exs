defmodule Tymeslot.AnalyticsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :context

  alias Tymeslot.Analytics
  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Factory
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

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
end
