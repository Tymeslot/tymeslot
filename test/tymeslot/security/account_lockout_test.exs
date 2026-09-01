defmodule Tymeslot.Security.AccountLockoutTest do
  @moduledoc false

  use Tymeslot.DataCase, async: false

  @moduletag :security

  alias Tymeslot.Security.AccountLockout
  alias Tymeslot.Test.LogCapture

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

    test "returns {:error, :account_throttled, _} from the tenth attempt onwards" do
      for _i <- 1..10 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert {:error, :account_throttled, message} =
               AccountLockout.check_lockout_status(@test_identifier)

      assert message =~ "Too many failed attempts"
    end

    # Throttling is the only tier: piling on failures past the threshold never
    # escalates to a harder lock, and never stops throttling either.
    test "stays throttled, and only throttled, well past the threshold" do
      for _i <- 1..40 do
        AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert AccountLockout.get_failed_attempt_count(@test_identifier) == 40

      assert {:error, :account_throttled, message} =
               AccountLockout.check_lockout_status(@test_identifier)

      assert message =~ "Too many failed attempts"
    end

    test "the attempt that crosses the threshold is itself throttled" do
      for _i <- 1..9 do
        assert :ok = AccountLockout.check_and_record_attempt(@test_identifier, false)
      end

      assert {:error, :account_throttled, _message} =
               AccountLockout.check_and_record_attempt(@test_identifier, false)
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

  describe "failed-attempt logging" do
    # This line fires on every failed attempt, so it is the highest-volume
    # identifier in the auth path; it must never carry the raw address.
    test "masks the identifier on both the first and subsequent attempts" do
      email = "lockout-log-#{System.unique_integer([:positive])}@example.com"
      on_exit(fn -> AccountLockout.clear_failed_attempts(email) end)

      LogCapture.with_capture([logger_level: :info], fn ->
        AccountLockout.check_and_record_attempt(email, false)
        AccountLockout.check_and_record_attempt(email, false)
      end)

      first = LogCapture.await_log("First failed attempt recorded")
      assert LogCapture.user_metadata(first).identifier_masked == "l***@example.com"
      refute LogCapture.dump(first) =~ email

      subsequent = LogCapture.await_log("Failed attempt recorded")
      meta = LogCapture.user_metadata(subsequent)
      assert meta.identifier_masked == "l***@example.com"
      assert meta.total_attempts == 2
      refute LogCapture.dump(subsequent) =~ email
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
      assert count == 20
    end
  end
end
