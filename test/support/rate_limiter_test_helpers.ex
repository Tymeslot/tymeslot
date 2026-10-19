defmodule Tymeslot.RateLimiterTestHelpers do
  @moduledoc """
  Reusable test helpers for rate limiter testing, particularly for concurrent access patterns.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.RateLimiter.Helpers
  alias Tymeslot.Security.RateLimiter.Limits

  @doc """
  Spends the named limit's whole budget for `key`, through `RateLimiter.check/2`
  as the code under test would, and returns the refusal's message. The bucket
  is cleared when the test exits.

  The bucket is shared by every test charging the same key, so an IP-scoped
  limit wants an address of the test's own (a unique `remote_ip`).
  """
  @spec exhaust_limit!(Limits.name(), term()) :: String.t()
  def exhaust_limit!(name, key) do
    entry = Limits.fetch!(name)
    on_exit(fn -> RateLimiter.clear_bucket("#{entry[:prefix]}:#{bucket_suffix(entry, key)}") end)

    result =
      Enum.reduce_while(0..Keyword.fetch!(entry, :limit), nil, fn _hit, _result ->
        case RateLimiter.check(name, key) do
          :ok -> {:cont, :ok}
          refused -> {:halt, refused}
        end
      end)

    assert {:error, :rate_limited, message} = result
    message
  end

  defp bucket_suffix(entry, key) do
    case entry[:scope] do
      :source -> Helpers.source_key(key)
      _user_id_or_key -> to_string(key)
    end
  end

  @doc """
  Tests that multiple users can operate concurrently without interfering with each other's rate limits.

  This helper verifies that each user has their own isolated rate limit bucket by:
  1. Making concurrent requests from multiple users
  2. Grouping results by user
  3. Asserting each user's requests succeeded independently

  ## Parameters

    * `user_ids` - List of user IDs to test concurrently
    * `requests_per_user` - Number of concurrent requests each user should make
    * `rate_limit_check_fn` - Function that takes a user_id and returns the rate limit check result

  ## Examples

      # Test with 5 users making 100 requests each
      test_multiple_users_operate_independently(
        [1000, 2000, 3000, 4000, 5000],
        100,
        &RateLimiter.check(:theme_customization, &1)
      )
  """
  @spec test_multiple_users_operate_independently(
          [integer()],
          integer(),
          (integer() -> :ok | {:error, :rate_limited, String.t()})
        ) :: :ok
  def test_multiple_users_operate_independently(
        user_ids,
        requests_per_user,
        rate_limit_check_fn
      ) do
    # Each user makes the specified number of concurrent requests
    tasks =
      for user_id <- user_ids,
          _i <- 1..requests_per_user do
        Task.async(fn ->
          {user_id, rate_limit_check_fn.(user_id)}
        end)
      end

    results = Task.await_many(tasks, 10_000)

    # Group results by user
    results_by_user = Enum.group_by(results, fn {user_id, _result} -> user_id end)

    # Each user should have all their requests succeed (assuming requests_per_user < limit)
    for user_id <- user_ids do
      user_results = Map.get(results_by_user, user_id, [])
      successes = Enum.count(user_results, fn {_user_id, result} -> result == :ok end)

      assert successes == requests_per_user,
             "User #{user_id} should have #{requests_per_user} successes, got #{successes}"
    end

    :ok
  end
end
