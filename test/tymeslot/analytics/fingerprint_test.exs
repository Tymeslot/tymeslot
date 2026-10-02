defmodule Tymeslot.Analytics.FingerprintTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :analytics

  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Analytics.Fingerprint
  alias Tymeslot.Analytics.SaltQueries
  alias Tymeslot.Analytics.SaltSchema

  # A day no other test module hashes on, so this module's uncommitted salt rows
  # never contend with those of concurrently running tests.
  @day ~D[2033-04-20]

  setup do
    freeze_clock(DateTime.new!(@day, ~T[12:00:00], "Etc/UTC"))
    # The per-node salt cache outlives each test's rolled-back salt row; start
    # every test from the database, as a freshly booted node would.
    forget_cached_salt()
    :ok
  end

  defp forget_cached_salt, do: :persistent_term.erase({Fingerprint, :daily_salt})

  describe "daily salt" do
    test "salts every hash of a day with that day's stored salt" do
      salt = SaltQueries.get_or_create(@day)

      expected =
        :sha256
        |> :crypto.hash(Enum.join(["1.2.3.4", "Mozilla/5.0", salt], "|"))
        |> Base.encode16(case: :lower)

      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") == expected
    end

    test "creates the day's salt on the first hash of the day" do
      Fingerprint.hash("1.2.3.4", "Mozilla/5.0")

      assert %SaltSchema{salt: <<_salt::binary-size(32)>>} = Repo.get(SaltSchema, @day)
    end

    test "gives the same visitor the same hash all day, on every node" do
      morning = Fingerprint.hash("1.2.3.4", "Mozilla/5.0")

      # Another node starts with no cached salt and must read the shared one.
      forget_cached_salt()
      freeze_clock(DateTime.new!(@day, ~T[23:59:59], "Etc/UTC"))

      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") == morning
    end

    test "gives the same visitor a different hash the next day" do
      today = Fingerprint.hash("1.2.3.4", "Mozilla/5.0")

      freeze_clock(DateTime.new!(Date.add(@day, 1), ~T[00:00:00], "Etc/UTC"))

      refute Fingerprint.hash("1.2.3.4", "Mozilla/5.0") == today
    end

    test "cannot recompute a day's hashes once that day's salt is deleted" do
      original = Fingerprint.hash("1.2.3.4", "Mozilla/5.0")

      # A salt derived from the date and a secret would come back identical
      # here; a random one is gone for good.
      Repo.delete!(Repo.get!(SaltSchema, @day))
      forget_cached_salt()

      refute Fingerprint.hash("1.2.3.4", "Mozilla/5.0") == original
    end
  end

  describe "hash/3" do
    test "produces a stable hash for the same inputs on the same day" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") ==
               Fingerprint.hash("1.2.3.4", "Mozilla/5.0")
    end

    test "produces a different hash for a different IP" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") !=
               Fingerprint.hash("5.6.7.8", "Mozilla/5.0")
    end

    test "produces a different hash for a different user agent" do
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0") !=
               Fingerprint.hash("1.2.3.4", "curl/8.0")
    end

    test "ignores the session id when a network identity is present" do
      # The same visitor browsing different meeting types arrives over
      # distinct LiveView connections (distinct session ids) but must count
      # as one unique visitor — the network identity wins.
      assert Fingerprint.hash("1.2.3.4", "Mozilla/5.0", "session-a") ==
               Fingerprint.hash("1.2.3.4", "Mozilla/5.0", "session-b")
    end

    test "falls back to the session id when ip and user_agent are both nil" do
      hash = Fingerprint.hash(nil, nil, "session-abc")
      assert hash =~ ~r/^[0-9a-f]{64}$/

      # Distinct anonymous connections remain distinct visitors, so the
      # unique count stays consistent with the visit count.
      assert Fingerprint.hash(nil, nil, "session-abc") !=
               Fingerprint.hash(nil, nil, "session-xyz")
    end

    test "returns nil only when there is nothing to hash" do
      assert Fingerprint.hash(nil, nil, nil) == nil
      assert Fingerprint.hash(nil, nil) == nil
    end

    test "treats the \"unknown\"/blank sentinels as an absent network identity" do
      # A caller passing the raw "unknown" sentinel must derive the *same* hash as
      # a caller that pre-normalised to nil — otherwise a visitor's page-view and
      # booking would split across two join keys.
      assert Fingerprint.hash("unknown", "unknown", "session-abc") ==
               Fingerprint.hash(nil, nil, "session-abc")

      assert Fingerprint.hash("", "", "session-abc") ==
               Fingerprint.hash(nil, nil, "session-abc")

      # Engaging the session fallback, distinct sessions stay distinct.
      assert Fingerprint.hash("unknown", "unknown", "session-abc") !=
               Fingerprint.hash("unknown", "unknown", "session-xyz")
    end

    test "returns a hash when ip is present but user_agent is nil" do
      hash = Fingerprint.hash("1.2.3.4", nil)
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "returns a hash when user_agent is present but ip is nil" do
      hash = Fingerprint.hash(nil, "Mozilla/5.0")
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end

    test "produces a 64-char lowercase hex string" do
      hash = Fingerprint.hash("1.2.3.4", "Mozilla/5.0")
      assert hash =~ ~r/^[0-9a-f]{64}$/
    end
  end
end
