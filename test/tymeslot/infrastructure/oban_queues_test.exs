defmodule Tymeslot.Infrastructure.ObanQueuesTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.ObanQueues

  describe "merge/3" do
    test "merges additional queues over base queues" do
      queues =
        ObanQueues.merge([default: 5, emails: 5], [emails: 8, payments: 2], pool_size: 10)

      assert Enum.sort(queues) == [default: 5, emails: 8, payments: 2]
    end

    test "falls back to a minimal default queue when nothing is configured" do
      assert capture_log(fn ->
               assert ObanQueues.merge([], [], pool_size: 10) == [default: 1]
             end) =~ "No Oban queues configured"
    end

    test "rejects concurrency above the pool size" do
      assert_raise ArgumentError, ~r/concurrency \(12\) exceeds pool_size \(10\)/, fn ->
        ObanQueues.merge([default: 12], [], pool_size: 10)
      end
    end

    test "rejects concurrency above the pool size in additional queues" do
      assert_raise ArgumentError, ~r/Queue payments concurrency \(12\)/, fn ->
        ObanQueues.merge([default: 5], [payments: 12], pool_size: 10)
      end
    end

    test "rejects non-integer and non-positive concurrency" do
      assert_raise ArgumentError, ~r/must be an integer/, fn ->
        ObanQueues.merge([default: "10"], [], pool_size: 10)
      end

      assert_raise ArgumentError, ~r/must be positive/, fn ->
        ObanQueues.merge([default: 0], [], pool_size: 10)
      end
    end

    test "rejects queue lists that are not keyword lists" do
      # A string queue name is the realistic slip: it looks like a keyword list
      # but Oban needs atoms.
      assert_raise ArgumentError, ~r/:oban_queues must be a keyword list/, fn ->
        ObanQueues.merge([{"default", 10}], [], pool_size: 10)
      end

      assert_raise ArgumentError, ~r/:oban_additional_queues must be a keyword list/, fn ->
        ObanQueues.merge([default: 10], [:payments], pool_size: 10)
      end
    end

    for mode <- [:manual, :inline] do
      test "skips the pool check in #{mode} testing mode, where Oban drops the queues" do
        queues =
          ObanQueues.merge([default: 10], [], pool_size: 8, testing: unquote(mode))

        assert queues == [default: 10]
      end
    end
  end

  describe "build/1" do
    test "adds the configured queues to the Oban config" do
      config = ObanQueues.build(repo: Tymeslot.Repo, testing: :manual)

      assert Keyword.get(config, :repo) == Tymeslot.Repo
      assert Keyword.get(config, :testing) == :manual
      assert Keyword.get(config, :queues) == Application.get_env(:tymeslot, :oban_queues)
    end

    test "keeps the queues out of the pool check while Oban is in testing mode" do
      # The suite itself boots this way: Oban drops the queue list in :manual
      # mode, so a pool smaller than the declared concurrency is not an error.
      config = ObanQueues.build(repo: Tymeslot.Repo, testing: :manual)

      assert Keyword.get(config, :queues)[:default] == 10
    end
  end
end
