defmodule Tymeslot.Precommit.PassRecordTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support
  @moduletag :tmp_dir

  alias Tymeslot.Precommit.PassRecord

  @credo {"credo", ~w[credo --strict lib/a.ex], :dev}
  @suite {"test", ~w[test], :test}
  @selection {"test", ~w[test test/a_test.exs], :test}
  @hex {"hex.audit", ~w[hex.audit], :dev}

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(Path.join(repo, "lib"))
    {_out, 0} = System.cmd("git", ["init", "--quiet"], cd: repo, env: [])
    File.write!(Path.join(repo, "lib/a.ex"), "defmodule A, do: nil\n")

    %{repo: repo, opts: [dir: repo, path: Path.join(dir, "passes")]}
  end

  defp pass(record, steps),
    do:
      PassRecord.save(record, steps, Enum.map(steps, fn {name, _a, _e} -> {name, :passed, 0} end))

  test "a step that passed is not run again on the same tree", ctx do
    assert {[@credo], []} = PassRecord.split(PassRecord.open(ctx.opts), [@credo])

    pass(PassRecord.open(ctx.opts), [@credo])

    assert PassRecord.split(PassRecord.open(ctx.opts), [@credo]) ==
             {[], [{"credo", "passed on this tree already"}]}
  end

  test "an edit, even uncommitted and untracked, makes it a different tree", ctx do
    pass(PassRecord.open(ctx.opts), [@credo])

    File.write!(Path.join(ctx.repo, "lib/b.ex"), "defmodule B, do: nil\n")

    assert {[@credo], []} = PassRecord.split(PassRecord.open(ctx.opts), [@credo])
  end

  test "hashing the tree leaves the real index alone", ctx do
    PassRecord.open(ctx.opts)

    assert {"", 0} = System.cmd("git", ["ls-files"], cd: ctx.repo, env: [])
  end

  test "a failed step is not recorded", ctx do
    PassRecord.save(PassRecord.open(ctx.opts), [@credo], [{"credo", :failed, 1}])

    assert {[@credo], []} = PassRecord.split(PassRecord.open(ctx.opts), [@credo])
  end

  test "a full suite pass covers any selection, but a selection does not cover the suite", ctx do
    pass(PassRecord.open(ctx.opts), [@suite])
    assert {[], [_passed]} = PassRecord.split(PassRecord.open(ctx.opts), [@selection])

    File.write!(Path.join(ctx.repo, "lib/a.ex"), "defmodule A, do: 1\n")
    pass(PassRecord.open(ctx.opts), [@selection])
    assert {[@suite], []} = PassRecord.split(PassRecord.open(ctx.opts), [@suite])
  end

  test "the suite with migrations included is not covered by a pass without them", ctx do
    pass(PassRecord.open(ctx.opts), [@suite])
    migrations = {"test", ~w[test --include migrations], :test}

    assert {[^migrations], []} = PassRecord.split(PassRecord.open(ctx.opts), [migrations])
  end

  test "hex.audit is never recorded, since its answer is not in the tree", ctx do
    pass(PassRecord.open(ctx.opts), [@hex])

    assert {[@hex], []} = PassRecord.split(PassRecord.open(ctx.opts), [@hex])
  end

  test "a tree that moved during the run records nothing", ctx do
    record = PassRecord.open(ctx.opts)
    File.write!(Path.join(ctx.repo, "lib/a.ex"), "defmodule A, do: 2\n")
    pass(record, [@credo])

    File.write!(Path.join(ctx.repo, "lib/a.ex"), "defmodule A, do: nil\n")
    assert {[@credo], []} = PassRecord.split(PassRecord.open(ctx.opts), [@credo])
  end

  test "outside a git repository nothing is skipped or saved", %{opts: opts} do
    path = opts[:path]
    # ExUnit's tmp_dir sits inside this repository, so the system one is used.
    dir = Path.join(System.tmp_dir!(), "pass-record-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    record = PassRecord.open(dir: dir, path: path)
    pass(record, [@credo])

    assert {[@credo], []} = PassRecord.split(record, [@credo])
    refute File.exists?(path)
  end
end
