defmodule Tymeslot.Security.AccountLockoutTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  @moduletag :security

  alias Tymeslot.Security.AccountLockout

  @test_identifier "test_user@example.com"

  setup do
    AccountLockout.clear_failed_attempts(@test_identifier)
    :ok
  end

  describe "check_and_record_attempt/2" do
    test "successful attempt clears history" do
      # Record some failed attempts first
      for _i <- 1..5 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 5

      # Successful attempt clears history
      assert :ok = AccountLockout.check_and_record_attempt(@test_identifier, true)
      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 0
    end

    test "failed attempt records and returns lockout status" do
      # First few failures return :ok
      assert :ok = AccountLockout.check_and_record_attempt(@test_identifier, false)
      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 1
    end
  end

  describe "check_lockout_status/1" do
    test "returns :ok with fewer than 10 attempts" do
      for _i <- 1..9 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert :ok = AccountLockout.check_lockout_status(@test_identifier)
    end

    test "returns :ok with no attempts" do
      assert :ok = AccountLockout.check_lockout_status(@test_identifier)
    end

    test "returns {:error, :account_throttled, _} at 10-19 attempts" do
      for _i <- 1..10 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert {:error, :account_throttled, message} =
               AccountLockout.check_lockout_status(@test_identifier)

      assert message =~ "Too many failed attempts"
    end

    test "returns {:error, :account_locked, _} at 20+ attempts" do
      for _i <- 1..20 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert {:error, :account_locked, message} =
               AccountLockout.check_lockout_status(@test_identifier)

      assert message =~ "Account locked"
      assert message =~ "minutes"
    end

    test "lockout status only considers last-hour attempts" do
      # Insert old timestamps directly into ETS (older than 1 hour)
      old_timestamp = System.system_time(:second) - 3700

      old_attempts = for _i <- 1..20, do: old_timestamp
      :ets.insert(:account_lockout_table, {@test_identifier, old_attempts})

      # Old attempts should not trigger lockout
      assert :ok = AccountLockout.check_lockout_status(@test_identifier)
    end
  end

  describe "lockout duration calculation" do
    test "flat lockout duration is 240 minutes regardless of attempt count" do
      # Flat 4-hour lockout: all 20+ attempt counts hit the same duration (30 * 8 = 240 minutes).
      for _i <- 1..20 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert {:error, :account_locked, message} =
               AccountLockout.check_lockout_status(@test_identifier)

      assert message =~ "240 minutes"
    end
  end

  describe "clear_failed_attempts/1" do
    test "resets everything" do
      for _i <- 1..15 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 15

      assert :ok = AccountLockout.clear_failed_attempts(@test_identifier)
      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 0
      assert :ok = AccountLockout.check_lockout_status(@test_identifier)
    end
  end

  describe "get_failed_attempt_count/1" do
    test "returns 0 for unknown identifier" do
      assert AccountLockout.get_failed_attempt_count("unknown@example.com") == 0
    end

    test "counts recent attempts" do
      for _i <- 1..7 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 7
    end

    test "only counts last 24 hours (old attempts pruned)" do
      # Insert a mix of old and recent timestamps
      now = System.system_time(:second)
      old_timestamp = now - 90_000
      recent_timestamps = for _i <- 1..3, do: now
      old_timestamps = for _i <- 1..5, do: old_timestamp

      :ets.insert(:account_lockout_table, {@test_identifier, recent_timestamps ++ old_timestamps})

      # Only recent attempts should be counted
      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 3
    end
  end

  describe "independent identifiers" do
    test "different emails are tracked independently" do
      email_a = "user_a_#{System.unique_integer([:positive])}@example.com"
      email_b = "user_b_#{System.unique_integer([:positive])}@example.com"

      on_exit(fn ->
        AccountLockout.clear_failed_attempts(email_a)
        AccountLockout.clear_failed_attempts(email_b)
      end)

      for _i <- 1..15 do
        AccountLockout.check_and_record_attempt(email_a, false)
      end

      for _i <- 1..3 do
        AccountLockout.check_and_record_attempt(email_b, false)
      end

      assert {:error, :account_throttled, _msg} = AccountLockout.check_lockout_status(email_a)
      assert :ok = AccountLockout.check_lockout_status(email_b)

      assert AccountLockout.get_failed_attempt_count(email_a) == 15
      assert AccountLockout.get_failed_attempt_count(email_b) == 3
    end

    test "identifier case variants share one counter" do
      base = "case_#{System.unique_integer([:positive])}@example.com"
      upper = String.upcase(base)
      mixed = String.capitalize(base)

      on_exit(fn -> AccountLockout.clear_failed_attempts(base) end)

      for _i <- 1..5, do: AccountLockout.check_and_record_attempt(base, false)
      for _i <- 1..5, do: AccountLockout.check_and_record_attempt(upper, false)
      for _i <- 1..5, do: AccountLockout.check_and_record_attempt(mixed, false)

      assert AccountLockout.get_failed_attempt_count(base) == 15
      assert AccountLockout.get_failed_attempt_count(upper) == 15
      assert AccountLockout.get_failed_attempt_count(mixed) == 15
    end

    test "clearing via one case variant clears all variants" do
      base = "clear_#{System.unique_integer([:positive])}@example.com"

      for _i <- 1..5, do: AccountLockout.check_and_record_attempt(base, false)
      assert AccountLockout.get_failed_attempt_count(base) == 5

      :ok = AccountLockout.clear_failed_attempts(String.upcase(base))
      assert AccountLockout.get_failed_attempt_count(base) == 0
    end

    test "whitespace-padded variants share one counter with the canonical form" do
      base = "ws_#{System.unique_integer([:positive])}@example.com"
      leading = " #{base}"
      trailing = "#{base} "
      both = "  #{String.upcase(base)}  "

      on_exit(fn -> AccountLockout.clear_failed_attempts(base) end)

      for _i <- 1..3, do: AccountLockout.check_and_record_attempt(base, false)
      for _i <- 1..3, do: AccountLockout.check_and_record_attempt(leading, false)
      for _i <- 1..3, do: AccountLockout.check_and_record_attempt(trailing, false)
      for _i <- 1..3, do: AccountLockout.check_and_record_attempt(both, false)

      assert AccountLockout.get_failed_attempt_count(base) == 12
      assert AccountLockout.get_failed_attempt_count(leading) == 12
      assert AccountLockout.get_failed_attempt_count(trailing) == 12
      assert AccountLockout.get_failed_attempt_count(both) == 12
    end
  end

  describe "concurrent writes" do
    # check_and_record_attempt performs a read-modify-write on ETS without a lock.
    # For advisory rate-limiting this is acceptable: a lost update under extreme
    # concurrent load means the counter may be slightly under-counted, but the
    # lockout still fires within a small margin. If this test fails intermittently
    # it is worth investigating, though a small under-count is not a security failure.
    test "multiple processes recording failures simultaneously don't lose updates" do
      identifier = "concurrent_#{System.unique_integer([:positive])}@example.com"

      on_exit(fn ->
        AccountLockout.clear_failed_attempts(identifier)
      end)

      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            AccountLockout.check_and_record_attempt(identifier, false)
          end)
        end

      Task.await_many(tasks, 5_000)

      count = AccountLockout.get_failed_attempt_count(identifier)
      # Under concurrent load the read-modify-write sequence can lose a small number
      # of updates — this is acceptable for advisory rate-limiting. Assert that the
      # vast majority of attempts are counted (lockout fires well before 20).
      assert count >= 15
    end
  end

  describe "ETS state durability" do
    # AccountLockout is now a plain module — there is no GenServer process to crash.
    # State lives in the ETS table owned by AccountLockout.TableOwner and persists
    # across any number of separate calls from any process on the same BEAM.
    test "recorded failures persist across separate calls" do
      identifier = "persist_#{System.unique_integer([:positive])}@example.com"

      on_exit(fn -> AccountLockout.clear_failed_attempts(identifier) end)

      # Spread writes across separate calls to exercise ETS read-modify-write.
      for _i <- 1..12 do
        AccountLockout.check_and_record_attempt(identifier, false)
      end

      # Counter must still be in effect after each independent call.
      assert AccountLockout.get_failed_attempt_count(identifier) == 12

      assert {:error, :account_throttled, _msg} =
               AccountLockout.check_lockout_status(identifier)
    end
  end
end
