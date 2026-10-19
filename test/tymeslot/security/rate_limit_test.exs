defmodule Tymeslot.Security.RateLimitTest do
  # async: false: the restart test kills the limiter's table, which every
  # rate-limited test shares.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Tymeslot.Security.RateLimit

  @moduletag :security

  @second 1_000_000

  setup do
    {:ok, key: "rate-limit-test:#{System.unique_integer([:positive])}", t0: now()}
  end

  describe "every hit counts" do
    test "two hits in the same microsecond are both charged", %{key: key, t0: t0} do
      assert RateLimit.hit(key, 60_000, 1, t0) == {:allow, 1}
      assert {:deny, _wait} = RateLimit.hit(key, 60_000, 1, t0)
      assert RateLimit.get(key, 60_000) == 2
    end

    test "a concurrent burst is allowed no more than the limit", %{key: key} do
      results =
        1..50
        |> Task.async_stream(fn _i -> RateLimit.hit(key, 60_000, 10) end, max_concurrency: 50)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:allow, _count}, &1)) <= 10
    end
  end

  describe "the sliding window" do
    test "a hit stops counting exactly one window after it was made", %{key: key, t0: t0} do
      assert RateLimit.hit(key, 1_000, 1, t0) == {:allow, 1}
      assert RateLimit.hit(key, 1_000, 1, t0 + @second) == {:allow, 1}
    end

    test "a hit still counts until its window has passed", %{key: key, t0: t0} do
      assert RateLimit.hit(key, 1_000, 1, t0) == {:allow, 1}
      assert {:deny, _wait} = RateLimit.hit(key, 1_000, 1, t0 + @second - 1)
    end

    test "a refusal says how long until a retry is allowed", %{key: key, t0: t0} do
      fill = fn key ->
        for step <- 0..2,
            do: {:allow, _count} = RateLimit.hit(key, 60_000, 3, t0 + step * @second)

        RateLimit.hit(key, 60_000, 3, t0 + 3 * @second)
      end

      # Four kept hits expire at 60, 61, 62 and 63 s; a retry brings its own,
      # so two of them must have gone: the retry is allowed from 61 s.
      assert fill.(key) == {:deny, 58_000}
      refused_at = t0 + 3 * @second

      assert RateLimit.hit(key, 60_000, 3, refused_at + 58_000 * 1000) == {:allow, 3}

      sooner = key <> ":sooner"
      assert fill.(sooner) == {:deny, 58_000}
      assert {:deny, _wait} = RateLimit.hit(sooner, 60_000, 3, refused_at + 57_999 * 1000)
    end
  end

  describe "retry_after/2" do
    test "names the same wait a refusal does, without charging", %{key: key, t0: t0} do
      RateLimit.hit(key, 60_000, 1, t0)
      assert {:deny, wait} = RateLimit.hit(key, 60_000, 1, t0)

      assert RateLimit.retry_after(key, 1) in (wait - 1)..wait
      assert length(RateLimit.entries(key)) == 2
    end

    # A bucket cleared between a refusal's count and its read of the rows
    # leaves nothing to wait for; the refusal shares this path.
    test "is nothing for an empty bucket, whatever the limit", %{key: key} do
      assert RateLimit.retry_after(key, 3) == 0
      assert RateLimit.retry_after(key, 0) == 0
    end

    test "is nothing while a hit would still fit", %{key: key} do
      RateLimit.hit(key, 60_000, 3)
      assert RateLimit.retry_after(key, 3) == 0
    end
  end

  describe "a flood past the limit" do
    test "stays refused while it lasts, holding no more than limit + 1 hits", %{key: key, t0: t0} do
      # One hit every 100 ms for five seconds against 3 per second: had refused
      # hits not counted, three of them would get through in every second.
      results =
        for step <- 0..49 do
          at = t0 + step * div(@second, 10)
          result = RateLimit.hit(key, 1_000, 3, at)
          assert length(RateLimit.entries(key)) <= 4
          {step, result}
        end

      assert for({step, {:allow, _count}} <- results, do: step) == [0, 1, 2]
    end

    test "ends one window after the hits stop", %{key: key, t0: t0} do
      last = t0 + 49 * div(@second, 10)

      for step <- 0..49, do: RateLimit.hit(key, 1_000, 3, t0 + step * div(@second, 10))

      assert RateLimit.hit(key, 1_000, 3, last + @second) == {:allow, 1}
    end
  end

  describe "clearing" do
    test "clear/1 drops one bucket and leaves the others", %{key: key, t0: t0} do
      other = key <> ":other"
      RateLimit.hit(key, 60_000, 5, t0)
      RateLimit.hit(other, 60_000, 5, t0)

      assert RateLimit.clear(key) == :ok

      assert RateLimit.entries(key) == []
      assert [{^t0, _expires_at}] = RateLimit.entries(other)
    end

    test "the periodic sweep drops expired hits from every bucket", %{key: key, t0: t0} do
      other = key <> ":other"
      live = key <> ":live"
      RateLimit.hit(key, 1_000, 5, t0 - 2 * @second)
      RateLimit.hit(other, 1_000, 5, t0 - 2 * @second)
      RateLimit.hit(live, 60_000, 5, t0)

      assert RateLimit.sweep(t0) >= 2

      assert RateLimit.entries(key) == []
      assert RateLimit.entries(other) == []
      assert [{^t0, _expires_at}] = RateLimit.entries(live)
    end
  end

  describe "when the table's owner restarts" do
    test "checks and clears succeed in the gap and buckets work again after it", %{key: key} do
      supervisor = Process.whereis(Tymeslot.Supervisor)
      owner = Process.whereis(RateLimit)
      ref = Process.monitor(owner)

      # Holding the supervisor keeps the owner down until the test lets it
      # restart, so the gap cannot close before the checks land in it.
      :ok = :sys.suspend(supervisor)

      log =
        try do
          Process.exit(owner, :kill)
          assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

          capture_log([level: :warning], fn ->
            assert RateLimit.hit(key, 60_000, 1) == {:allow, 0}
            assert RateLimit.hit(key, 60_000, 1) == {:allow, 0}
            assert RateLimit.get(key, 60_000) == 0
            assert RateLimit.clear(key) == :ok
          end)
        after
          :sys.resume(supervisor)
        end

      assert length(String.split(log, "Rate limit table missing")) == 2,
             "expected the gap to be logged exactly once, got: #{log}"

      # The supervisor handles the owner's exit before this call, so the
      # owner is back once it returns.
      _state = :sys.get_state(supervisor)
      assert Process.whereis(RateLimit) not in [nil, owner]

      assert RateLimit.hit(key, 60_000, 1) == {:allow, 1}
      assert {:deny, _wait} = RateLimit.hit(key, 60_000, 1)
    end
  end

  defp now, do: RateLimit.now()
end
