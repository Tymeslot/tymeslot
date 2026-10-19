defmodule Tymeslot.Integrations.Shared.OAuth.RefreshTest do
  # async: false: the lock table is global.
  use ExUnit.Case, async: false

  @moduletag :integrations

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Integrations.Shared.Lock
  alias Tymeslot.Integrations.Shared.OAuth.Refresh

  @now ~U[2026-10-07 12:00:00Z]

  setup do
    freeze_clock(@now)
    %{key: Refresh.lock_key(:calendar, System.unique_integer([:positive]))}
  end

  defp expiring_in(seconds), do: %{token_expires_at: DateTime.add(@now, seconds, :second)}

  defp hooks(current, overrides \\ %{}) do
    Map.merge(
      %{
        fetch: fn -> {:ok, current} end,
        already_valid: fn current -> {:already_valid, current} end,
        refresh: fn _current -> {:ok, :new_tokens} end,
        persist: fn _current, tokens -> {:persisted, tokens} end
      },
      overrides
    )
  end

  describe "valid?/2" do
    test "holds only while the expiry is further out than the buffer, on the frozen clock" do
      assert Refresh.valid?(DateTime.add(@now, 301, :second))
      refute Refresh.valid?(DateTime.add(@now, 300, :second))
      assert Refresh.valid?(DateTime.add(@now, 61, :second), 60)
    end

    test "treats an unknown expiry as needing a refresh" do
      refute Refresh.valid?(nil)
    end
  end

  describe "lock_key/2" do
    test "keeps calendar and video integrations with the same id apart" do
      refute Refresh.lock_key(:calendar, 1) == Refresh.lock_key(:video, 1)
    end
  end

  describe "run/3" do
    test "answers from the re-read row without refreshing when it is still valid", %{key: key} do
      current = expiring_in(3600)
      overrides = %{refresh: fn _current -> flunk("refreshed a valid token") end}

      assert {:already_valid, ^current} = Refresh.run(key, hooks(current, overrides))
    end

    test "refreshes and persists a row whose token expires within the buffer", %{key: key} do
      current = expiring_in(299)

      overrides = %{
        refresh: fn ^current -> {:ok, :new_tokens} end,
        persist: fn ^current, :new_tokens -> {:persisted, :new_tokens} end
      }

      assert {:persisted, :new_tokens} = Refresh.run(key, hooks(current, overrides))
    end

    test "takes the validity buffer from the options", %{key: key} do
      current = expiring_in(3600)

      assert {:persisted, :new_tokens} =
               Refresh.run(key, hooks(current), buffer_seconds: 7200)
    end

    test "lets the caller decide validity", %{key: key} do
      current = expiring_in(3600)

      assert {:persisted, :new_tokens} =
               Refresh.run(key, hooks(current, %{valid?: fn _current -> false end}))
    end

    # The guarantee the engine exists for: a caller queued behind this one
    # must find the new tokens on the row when it gets the lock.
    test "persists before releasing the lock", %{key: key} do
      test_pid = self()

      persist = fn _current, tokens ->
        send(test_pid, {:held_while_persisting, contender_result(key)})
        {:persisted, tokens}
      end

      Refresh.run(key, hooks(expiring_in(0), %{persist: persist}))

      assert_received {:held_while_persisting, {:error, :refresh_in_progress}}
    end

    test "returns a refresh failure as it is, without persisting", %{key: key} do
      overrides = %{
        refresh: fn _current -> {:error, :unauthorized, "Token refresh failed: invalid_grant"} end,
        persist: fn _current, _tokens -> flunk("persisted a failed refresh") end
      }

      assert {:error, :unauthorized, "Token refresh failed: invalid_grant"} =
               Refresh.run(key, hooks(expiring_in(0), overrides))
    end

    test "stops with the error a re-read answers", %{key: key} do
      overrides = %{
        fetch: fn -> {:error, :requires_reencryption} end,
        refresh: fn _current -> flunk("refreshed after a failed re-read") end
      }

      assert {:error, :requires_reencryption} = Refresh.run(key, hooks(nil, overrides))
    end

    test "answers the refreshed value when there is no persist hook", %{key: key} do
      hooks = Map.delete(hooks(expiring_in(0)), :persist)

      assert {:ok, :new_tokens} = Refresh.run(key, hooks)
    end

    test "answers a lock timeout when another holder keeps the lock", %{key: key} do
      test_pid = self()

      holder =
        spawn(fn ->
          Lock.with_lock(key, fn ->
            send(test_pid, :lock_held)
            receive do: (:release -> :ok)
          end)
        end)

      assert_receive :lock_held

      assert {:error, :lock_timeout} =
               Refresh.run(key, hooks(expiring_in(0)), lock_timeout: 300)

      send(holder, :release)
    end
  end

  defp contender_result(key) do
    key
    |> then(&Task.async(fn -> Lock.with_lock(&1, fn -> :acquired end) end))
    |> Task.await()
  end
end
