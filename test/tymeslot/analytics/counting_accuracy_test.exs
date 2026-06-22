defmodule Tymeslot.Analytics.CountingAccuracyTest do
  @moduledoc """
  Deterministic counting harness. Replays a known traffic stream through the
  real ingestion path (`log_page_view/1` — bot filter, rate limit, fingerprint)
  and records matching bookings, then asserts the dashboard read functions
  return the exact ground-truth tallies, bots are excluded, and the
  self-consistency invariants hold without the conversion clamp doing any work.

  This proves the counting code is correct; it does not measure the inherent
  approximation of cookieless fingerprinting (collisions, daily-salt rotation),
  which is a separate, statistical question.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :analytics
  @moduletag :database

  import Tymeslot.Factory

  alias Tymeslot.Analytics
  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Analytics.Fingerprint
  alias Tymeslot.Security.RateLimiter

  setup do
    RateLimiter.clear_all()
    on_exit(&RateLimiter.clear_all/0)

    now = DateTime.utc_now()

    %{
      user: insert(:user),
      from: DateTime.add(now, -3600, :second),
      to: DateTime.add(now, 3600, :second)
    }
  end

  # Three distinct visitors with distinct network identities. `views` page
  # loads each; converters also book, carrying the same cookieless hash.
  @visitors [
    %{
      ip: "10.0.0.1",
      ua: "Mozilla/5.0 (A) Chrome/126",
      session: "s-a",
      source: "linkedin",
      views: 2,
      books: true
    },
    %{
      ip: "10.0.0.2",
      ua: "Mozilla/5.0 (B) Firefox/120",
      session: "s-b",
      source: "twitter",
      views: 1,
      books: true
    },
    %{
      ip: "10.0.0.3",
      ua: "Mozilla/5.0 (C) Safari/17",
      session: "s-c",
      source: "linkedin",
      views: 1,
      books: false
    }
  ]

  test "dashboard counts match a known traffic stream and invariants hold", ctx do
    %{user: user, from: from, to: to} = ctx

    replay_page_views(user)
    assert_bot_is_filtered(user)
    record_bookings(user)

    visits = Analytics.count_visits(user.id, from, to)
    unique = Analytics.count_unique_visitors(user.id, from, to)
    converting = Analytics.count_converting_visitors(user.id, from, to)

    # Ground truth: 4 views (A×2, B, C), 3 distinct visitors, 2 converters
    # (A, B). The bot view does not count.
    assert visits == 4
    assert unique == 3
    assert converting == 2
    assert Analytics.conversion_rate(converting, unique) == "66.7"

    # Invariants the counting must always satisfy — converting ≤ unique means
    # the conversion clamp never has to engage.
    assert unique <= visits
    assert converting <= unique

    assert_attribution(user, from, to)
  end

  defp replay_page_views(user) do
    for visitor <- @visitors, _i <- 1..visitor.views do
      assert {:ok, %EventSchema{}} =
               Analytics.log_page_view(%{
                 path: "/host/intro",
                 user_id: user.id,
                 meeting_type_id: nil,
                 ip: visitor.ip,
                 user_agent: visitor.ua,
                 session_id: visitor.session,
                 params: %{"utm_source" => visitor.source},
                 referrer: nil
               })
    end
  end

  defp assert_bot_is_filtered(user) do
    assert {:ok, :filtered_bot} =
             Analytics.log_page_view(%{
               path: "/host/intro",
               user_id: user.id,
               meeting_type_id: nil,
               ip: "10.0.0.9",
               user_agent: "Googlebot/2.1 (+http://www.google.com/bot.html)",
               session_id: "s-bot",
               params: %{"utm_source" => "linkedin"},
               referrer: nil
             })
  end

  defp record_bookings(user) do
    base = DateTime.utc_now(:second)

    @visitors
    |> Enum.filter(& &1.books)
    |> Enum.with_index(1)
    |> Enum.each(fn {visitor, i} ->
      insert(:meeting,
        organizer_user_id: user.id,
        start_time: DateTime.add(base, i * 60, :minute),
        end_time: DateTime.add(base, i * 60 + 30, :minute),
        utm_source: visitor.source,
        visitor_hash: Fingerprint.hash(visitor.ip, visitor.ua, visitor.session)
      )
    end)
  end

  defp assert_attribution(user, from, to) do
    rows = Analytics.attribution_table(user.id, from, to)
    linkedin = Enum.find(rows, &(&1.utm_source == "linkedin"))
    twitter = Enum.find(rows, &(&1.utm_source == "twitter"))

    # linkedin: A (×2 views, books) + C (1 view, no book)
    assert %{visits: 3, unique_visitors: 2, bookings: 1, converting_visitors: 1} = linkedin
    # twitter: B (1 view, books)
    assert %{visits: 1, unique_visitors: 1, bookings: 1, converting_visitors: 1} = twitter
  end
end
