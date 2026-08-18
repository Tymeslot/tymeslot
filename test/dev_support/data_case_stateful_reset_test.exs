defmodule Tymeslot.DataCaseAsyncStatefulResetTest do
  # The guard under test, from the async side. Both modules here prime a
  # rate-limit bucket in `setup_all` and then assert, from a test body, whether
  # the per-test setup that ran in between wiped it.
  use Tymeslot.DataCase, async: true

  @moduletag :dev_support

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter

  setup_all do
    {:ok, bucket_key: prime_bucket("async")}
  end

  test "an async module's setup leaves the shared rate-limiter table alone", %{
    bucket_key: bucket_key
  } do
    assert :ets.match_object(RateLimit, {{bucket_key, :_}, :_}) != [],
           "the per-test setup cleared a bucket primed before it, which is a " <>
             "table-wide delete racing every other async test in the VM"
  end

  test "an async test can still scope a reset to its own bucket" do
    bucket_key = prime_bucket("async-scoped")
    assert :ets.match_object(RateLimit, {{bucket_key, :_}, :_}) != []

    RateLimiter.clear_bucket(bucket_key)

    assert :ets.match_object(RateLimit, {{bucket_key, :_}, :_}) == []
  end

  defp prime_bucket(label) do
    bucket_key = "#{label}-reset-#{System.unique_integer([:positive])}"
    {:allow, _count} = RateLimiter.check_rate(bucket_key, :timer.minutes(5), 10)
    bucket_key
  end
end

defmodule Tymeslot.DataCaseSyncStatefulResetTest do
  # The other half: sync modules must still get the reset. They run only once
  # every async module has finished, and one at a time, so clearing global
  # state from here races nothing.
  use Tymeslot.DataCase, async: false

  @moduletag :dev_support

  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter

  setup_all do
    bucket_key = "sync-reset-#{System.unique_integer([:positive])}"
    {:allow, _count} = RateLimiter.check_rate(bucket_key, :timer.minutes(5), 10)
    {:ok, bucket_key: bucket_key}
  end

  test "a sync module's setup still clears the shared rate-limiter table", %{
    bucket_key: bucket_key
  } do
    assert :ets.match_object(RateLimit, {{bucket_key, :_}, :_}) == []
  end
end
